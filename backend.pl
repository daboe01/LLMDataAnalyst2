#!/usr/bin/env perl
# LLMDataAnalyst - Multi-Provider Backend
use Mojolicious::Lite -signatures;
use Mojo::UserAgent;
use Mojo::JSON qw(decode_json encode_json);
use Statistics::R;
use File::Temp qw(tempdir tempfile);
use File::Basename;
use File::Spec;
use Encode;
use POSIX qw(strftime);
use Data::Dumper;

no warnings 'uninitialized';

my $ua = Mojo::UserAgent->new(request_timeout => 60, inactivity_timeout => 60);
$ua->max_connections(0);

my %SESSIONS;

# ==========================================
# CORS-SUPPORT (Für lokale Entwicklungsports)
# ==========================================
app->hook(before_dispatch => sub ($c) {
    $c->res->headers->header('Access-Control-Allow-Origin'  => '*');
    $c->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST, OPTIONS, PUT, DELETE');
    $c->res->headers->header('Access-Control-Allow-Headers' => 'Content-Type, Authorization, X-Requested-With');
    
    if ($c->req->method eq 'OPTIONS') {
        $c->render(text => '', status => 204);
        return;
    }
});

# ==========================================
# HELPER: Dynamischer Cloud LLM Client
# ==========================================
helper call_cloud_llm => sub ($c, $prompt, $config) {
   my $service  = $config->{service}  // 'ollama';
   my $model    = $config->{model}    // '';
   my $api_key  = $config->{api_key}  // '';
   my $endpoint = $config->{endpoint} // '';

   my $promise = Mojo::Promise->new;

   if ($service eq 'ollama') {
       # Ollama Integration (Lokal)
       my $url = $endpoint || 'http://localhost:11434/api/generate';
       my $payload = {
           model  => $model || 'llama3',
           prompt => $prompt,
           stream => \0
       };
       $ua->post($url => json => $payload => sub ($ua, $tx) {
           if ($tx->result->is_success) {
               my $res = eval { decode_json($tx->result->body) };
               $promise->resolve($res->{response} // '');
           } else {
               $promise->reject("Ollama Fehler: " . $tx->result->message);
           }
       });

   } elsif ($service eq 'groq') {
       # Groq Cloud API
       my $url = 'https://api.groq.com/openai/v1/chat/completions';
       my $payload = {
           model       => $model || 'llama3-8b-8192',
           messages    => [{ role => 'user', content => $prompt }],
           temperature => 0.1
       };
       my $headers = {
           'Authorization' => "Bearer $api_key",
           'Content-Type'  => 'application/json'
       };
       $ua->post($url => $headers => json => $payload => sub ($ua, $tx) {
           if ($tx->result->is_success) {
               my $res = eval { decode_json($tx->result->body) };
               $promise->resolve($res->{choices}[0]{message}{content} // '');
           } else {
               $promise->reject("Groq API Fehler: " . $tx->result->message);
           }
       });

   } elsif ($service eq 'gemini') {
       # Google Gemini API
       my $sel_model = $model || 'gemini-2.0-flash';
       my $url = "https://generativelanguage.googleapis.com/v1beta/models/${sel_model}:generateContent?key=${api_key}";
       my $payload = {
           contents => [{ parts => [{ text => $prompt }] }]
       };
       $ua->post($url => json => $payload => sub ($ua, $tx) {
           if ($tx->result->is_success) {
               my $res = eval { decode_json($tx->result->body) };
               $promise->resolve($res->{candidates}[0]{content}{parts}[0]{text} // '');
           } else {
               warn $tx->result->message;
               $promise->reject("Gemini API Fehler: " . $tx->result->message);
           }
       });

   } elsif ($service eq 'openrouter') {
       # OpenRouter Multi-Provider API
       my $url = 'https://openrouter.ai/api/v1/chat/completions';
       my $payload = {
           model    => $model || 'google/gemini-2.0-flash-001',
           messages => [{ role => 'user', content => $prompt }]
       };
       my $headers = {
           'Authorization' => "Bearer $api_key",
           'Content-Type'  => 'application/json'
       };
       $ua->post($url => $headers => json => $payload => sub ($ua, $tx) {
           if ($tx->result->is_success) {
               my $res = eval { decode_json($tx->result->body) };
               $promise->resolve($res->{choices}[0]{message}{content} // '');
           } else {
               warn $tx->result->message;
               $promise->reject("OpenRouter API Fehler: " . $tx->result->message);
           }
       });

   } else {
       $promise->reject("Unbekannte Schnittstelle: $service");
   }

   return $promise;
};

# ==========================================
# PROMPT GENERATOREN (Nativ ohne PromptDB-Zwang)
# ==========================================
sub prompt_for_loading ($filename, $preview) {
   return <<"PROMPT";
You are an expert R developer.
Carefully analyze the following file preview of '$filename' to determine its format, column separator (e.g., comma, semicolon, tab, or space), and decimal separator (comma or dot):

File Preview:
$preview

Write a robust R script using base R (such as read.csv, read.csv2, read.delim) or readr (read_delim) to load this file into a data frame named 'df'.
Make sure to explicitly specify the correct 'sep' (separator) and 'dec' (decimal) parameters matching the preview analysis to avoid parser failures like "more columns than column names" / "mehr Spalten als Spaltennamen". 

If the file extension indicates an Excel file (.xlsx or .xls), use 'readxl::read_excel'.

Return ONLY the executable R code to load the file.
Do not wrap your output in markdown formatting (like ```r or ```).
PROMPT
}

sub prompt_for_modification ($user_input, $current_code, $summary) {
   return <<"PROMPT";
You are a statistical data analysis assistant.
Modify the existing R code to satisfy the user's request.
User request: $user_input

Current R code:
$current_code

Current dataset summary:
$summary

Ensure that:
1. All changes are based on the data frame named 'df'.
2. Any plots or files generated are saved as static images (PNG) in the current directory.
3. You return ONLY the complete modified R code. No explanations, no markdown blocks.
PROMPT
}

sub prompt_for_repair ($error_msg, $failed_code) {
   return <<"PROMPT";
The following R code failed to run:
$failed_code

It resulted in this error message:
$error_msg

Fix the error, adjust the code, and return the corrected R code.
Return ONLY valid R code. No commentary. No markdown blocks.
PROMPT
}

# ==========================================
# HELPER: R Code Ausführung
# ==========================================
helper execute_r => sub ($c, $code, $workdir) {
   my ($fh, $temp_file) = tempfile(DIR => $workdir, SUFFIX => '.R', UNLINK => 1);
   binmode($fh, ':utf8');
   print $fh $code;
   close $fh;

   my $filename = basename($temp_file);

   my $R = Statistics::R->new(shared => 0);
   $R->startR;

   $R->run(qq{setwd("$workdir")});
   $R->run(qq{source("$filename", encoding = "UTF-8", echo = FALSE, print.eval = TRUE)});

   my $err = $R->error;
   my $out = $R->read;

   $R->stopR;
   unlink($temp_file) if -e $temp_file;

   $out = Encode::decode_utf8($out) if defined $out;
   $err = Encode::decode_utf8($err) if defined $err;

   return ($out, $err);
};

# ==========================================
# HELPER: Session-Speicherung & Laden
# ==========================================
helper save_session_data => sub ($c, $session_id, $data) {
   $SESSIONS{$session_id} = $data;
   my $tmpdir = File::Spec->tmpdir();
   my $filepath = "$tmpdir/llm_session_$session_id.json";
   if (open my $fh, '>', $filepath) {
       print $fh encode_json($data);
       close $fh;
   }
};

helper load_session_data => sub ($c, $session_id) {
   return $SESSIONS{$session_id} if exists $SESSIONS{$session_id};
   my $tmpdir = File::Spec->tmpdir();
   my $filepath = "$tmpdir/llm_session_$session_id.json";
   if (-e $filepath) {
       if (open my $fh, '<', $filepath) {
           local $/;
           my $json = <$fh>;
           close $fh;
           my $data = eval { decode_json($json) };
           if ($data) {
               $SESSIONS{$session_id} = $data;
               return $data;
           }
       }
   }
   return;
};

# ==========================================
# ROUTEN (API)
# ==========================================

post '/api/upload' => sub ($c) {
   my @uploads = $c->req->upload('files[]');
   my $upload = shift @uploads;

   return $c->render(json => {error => 'No file uploaded'}) unless $upload;
   my $session_id = $c->req->param('session_id');
   $session_id =~ s/[^a-zA-Z0-9_\-]//g if defined $session_id;
   
   if (!$session_id) {
       $session_id = 'session_' . time() . '_' . int(rand(1000));
   }

   my $config_json = $c->req->param('llm_config') // '{}';
   my $llm_config  = eval { decode_json($config_json) } // {};

   my $workdir = tempdir(CLEANUP => 0);
   my $filename = $upload->filename;
   my $filepath = "$workdir/$filename";
   $upload->move_to($filepath);

   my $first_500_bytes = "[Binaerdatei - keine Text-Vorschau verfuegbar]";
   if (-T $filepath) {
       open my $fh, '<', $filepath or return $c->render(json => {error => "Kann Datei nicht lesen: $!"});
       read($fh, $first_500_bytes, 500);
       close $fh;
       $first_500_bytes = Encode::decode_utf8($first_500_bytes);
   }

   my $initial_session = {
       workdir  => $workdir,
       filename => $filename,
       r_code   => "",
       summary  => "",
       history  => []
   };
   $c->save_session_data($session_id, $initial_session);

   $c->render_later;
   $c->inactivity_timeout(120); 

   my $prompt = prompt_for_loading($filename, $first_500_bytes);

   $c->call_cloud_llm($prompt, $llm_config)->then(sub ($r_code) {
       # Eventuell ausgegebene Markdown-Blöcke bereinigen
       $r_code =~ s/^```[rR]?\s*//gm;
       $r_code =~ s/```$//gm;

       $r_code .= "\noptions(width=1000)\nprint('---SUMMARY START---')\ncat('--- STRUKTUR ---\\n')\nstr(df)\ncat('\\n--- SUMMARY ---\\n')\nsummary(df)\n";

       my $session = $c->load_session_data($session_id);
       $session->{r_code} = $r_code;

       my ($out, $err) = $c->execute_r($r_code, $workdir);

       if ($err) {
           return $c->render(json => {error => "R-Ausfuehrungsfehler beim Laden", r_err => $err, code => $r_code});
       }

       my $summary = $out;
       $summary =~ s/.*---SUMMARY START---(?:\r?\n)?//s;

       $session->{summary} = $summary;
       $c->save_session_data($session_id, $session);

       $c->render(json => {
           session_id => $session_id,
           summary    => $summary,
           r_code     => $r_code
       });
   })->catch(sub ($err) {
       warn $err;
       $c->render(json => {error => "LLM-Dienstfehler: $err"}, status => 500);
   });
};

post '/api/chat' => sub ($c) {
   my $payload    = $c->req->json;
   my $session_id = $payload->{session_id};
   $session_id =~ s/[^a-zA-Z0-9_\-]//g if defined $session_id;

   my $user_input = $payload->{prompt};
   my $llm_config = $payload->{llm_config} // {};

   my $session = $c->load_session_data($session_id);
   return $c->render(json => {error => 'Sitzung nicht gefunden'}) unless $session;

   $c->render_later;
   $c->inactivity_timeout(120); 

   my $prompt = prompt_for_modification($user_input, $session->{r_code}, $session->{summary});

   $c->call_cloud_llm($prompt, $llm_config)->then(sub ($new_r_code) {
       $new_r_code =~ s/^```[rR]?\s*//gm;
       $new_r_code =~ s/```$//gm;

       my $attempt_run = sub {
           my ($code, $iteration, $retry_sub) = @_;

           my ($out, $err) = $c->execute_r($code, $session->{workdir});

           # Reparatur-Schleife bei syntaktischen Fehlern im R-Skript
           if ($err && $iteration < 3) {
               $c->app->log->warn("R-Fehler in Versuch $iteration. Starte Reparatur...");
               my $repair_prompt = prompt_for_repair($err, $code);
               return $c->call_cloud_llm($repair_prompt, $llm_config)->then(sub ($repaired_code) {
                   $repaired_code =~ s/^```[rR]?\s*//gm;
                   $repaired_code =~ s/```$//gm;
                   return $retry_sub->($repaired_code, $iteration + 1, $retry_sub);
               });
           }

           return Mojo::Promise->resolve({code => $code, out => $out, err => $err, attempts => $iteration});
       };

       return $attempt_run->($new_r_code, 1, $attempt_run);

   })->then(sub ($result) {

       $session->{r_code} = $result->{code};
       $c->save_session_data($session_id, $session);

       if ($result->{err}) {
           return $c->render(json => {
               success => \0,
               message => "Code-Ausfuehrung nach $result->{attempts} Versuchen fehlgeschlagen.",
               error   => $result->{err}
           });
       }

       opendir(my $dh, $session->{workdir});
       # Filtert ausschliesslich exportierte Plots/Grafiken fuer die native View heraus
       my @files = grep { !/^\./ && $_ ne $session->{filename} && $_ =~ /\.(?:png|jpe?g|gif|svg)$/i } readdir($dh);
       closedir($dh);

       my @downloads = map { "/api/download/file/$session_id/$_" } @files;

       $c->render(json => {
           success   => \1,
           output    => $result->{out},
           attempts  => $result->{attempts},
           downloads => \@downloads
       });

   })->catch(sub ($err) {
       warn $err;
       $c->render(json => {error => "Verarbeitungsfehler", details => "$err"}, status => 500);
   });
};

get '/api/download/script/:session_id' => sub ($c) {
   my $session_id = $c->param('session_id');
   $session_id =~ s/[^a-zA-Z0-9_\-]//g;

   my $session = $c->load_session_data($session_id);
   return $c->reply->not_found unless $session;

   $c->res->headers->content_disposition('attachment; filename="analysis.R"');
   $c->res->headers->header('Cache-Control' => 'no-cache, no-store, must-revalidate');
   $c->res->headers->header('Pragma'        => 'no-cache');
   $c->res->headers->header('Expires'       => '0');
   
   $c->render(text => $session->{r_code});
};

get '/api/download/file/:session_id/:filename' => [filename => qr /.+/] => sub ($c) {
   my $session_id = $c->param('session_id');
   $session_id =~ s/[^a-zA-Z0-9_\-]//g;

   my $filename = $c->param('filename');
   $filename =~ s|/||g;

   my $session = $c->load_session_data($session_id);
   return $c->reply->not_found unless $session;

   my $filepath = "$session->{workdir}/$filename";
   return $c->reply->not_found unless -e $filepath;

   $c->res->headers->content_disposition(qq{attachment; filename="$filename"});
   $c->res->headers->header('Cache-Control' => 'no-cache, no-store, must-revalidate');
   $c->res->headers->header('Pragma'        => 'no-cache');
   $c->res->headers->header('Expires'       => '0');

   $c->reply->file($filepath);
};

app->config(hypnotoad => {listen => ['http://*:3036'], workers => 1, heartbeat_timeout => 0, inactivity_timeout => 0});
app->start;

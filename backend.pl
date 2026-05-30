#!/usr/bin/env perl
# LLMDataAnalyst - Multi-Provider Backend with Native Tool Calling
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

my $ua = Mojo::UserAgent->new(request_timeout => 90, inactivity_timeout => 90);
$ua->max_connections(0);

my %SESSIONS;

# ==========================================
# CORS-SUPPORT (For local development ports)
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
# DEFINITION OF TOOLS (JSON SCHEMA)
# ==========================================
my $r_tool_schema = {
    type     => 'function',
    function => {
        name        => 'execute_r_code',
        description => 'Executes R statistical and mathematical code on the loaded dataset. '
                     . 'The dataset is already loaded into a dataframe named "df". '
                     . 'Use this tool for calculations, statistical tests (t-test, ANOVA, regression), '
                     . 'or to generate visualizations. Visualizations MUST be saved in the current directory '
                     . 'as BOTH a PNG (e.g., "plot.png") and a PDF (e.g., "plot.pdf") using the exact same base filename.',
        parameters  => {
            type       => 'object',
            properties => {
                code => {
                    type        => 'string',
                    description => 'The complete and executable R code.',
                },
            },
            required => ['code'],
        },
    },
};

my @available_tools = ($r_tool_schema);

# ==========================================
# HELPER: Dynamic Chat Client (with Tool Calling Support)
# ==========================================
helper call_chat_llm => sub ($c, $messages, $tools, $config) {
   my $service  = $config->{service}  // 'ollama';
   my $model    = $config->{model}    // '';
   my $api_key  = $config->{api_key}  // '';
   my $endpoint = $config->{endpoint} // '';

   my $promise = Mojo::Promise->new;

   if ($service eq 'ollama') {
       my $url = $endpoint;
       $url =~ s/generate/chat/;
       if ($url eq '') {
           $url = 'http://localhost:11434/api/chat';
       }

       my $payload = {
           model    => $model || 'gpt-oss:20b',
           messages => $messages,
           stream   => \0
       };
       $payload->{tools} = $tools if $tools && @$tools;

       $ua->post($url => json => $payload => sub ($ua, $tx) {
           if ($tx->result && $tx->result->is_success) {
               my $res = eval { decode_json($tx->result->body) };
               my $msg = $res->{message} // { role => 'assistant', content => '' };
               $promise->resolve({
                   role       => 'assistant',
                   content    => $msg->{content} // '',
                   tool_calls => $msg->{tool_calls} // []
               });
           } else {
               my $err_msg = $tx->error ? $tx->error->{message} : "Unknown Connection Error";
               $promise->reject("Ollama Connection Error: " . $err_msg);
           }
       });

   } elsif ($service eq 'groq' || $service eq 'openrouter') {
       my $url = $service eq 'groq' 
           ? 'https://api.groq.com/openai/v1/chat/completions'
           : 'https://openrouter.ai/api/v1/chat/completions';

       my $payload = {
           model       => $model || ($service eq 'groq' ? 'llama3-8b-8192' : 'google/gemini-2.0-flash-001'),
           messages    => $messages,
           temperature => 0.1
       };
       $payload->{tools} = $tools if $tools && @$tools;

       my $headers = {
           'Authorization' => "Bearer $api_key",
           'Content-Type'  => 'application/json'
       };

       $ua->post($url => $headers => json => $payload => sub ($ua, $tx) {
           if ($tx->result && $tx->result->is_success) {
               my $res = eval { decode_json($tx->result->body) };
               my $choice = $res->{choices}[0]{message};
               $promise->resolve({
                   role       => 'assistant',
                   content    => $choice->{content} // '',
                   tool_calls => $choice->{tool_calls} // []
               });
           } else {
               my $err_msg = $tx->error ? $tx->error->{message} : "Unknown Connection Error";
               $promise->reject("Cloud API Error ($service): " . $err_msg);
           }
       });

   } elsif ($service eq 'gemini') {
       # Google Gemini REST API utilizing official OpenAI Compatibility
       my $sel_model = $model || 'gemini-2.5-flash';
       my $url = 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions';

       my $payload = {
           model       => $sel_model,
           messages    => $messages,
           temperature => 0.1
       };
       $payload->{tools} = $tools if $tools && @$tools;

       my $headers = {
           'Authorization' => "Bearer $api_key",
           'Content-Type'  => 'application/json'
       };

       $ua->post($url => $headers => json => $payload => sub ($ua, $tx) {
           if ($tx->result && $tx->result->is_success) {
               my $res = eval { decode_json($tx->result->body) };
               my $choice = $res->{choices}[0]{message};
               $promise->resolve({
                   role       => 'assistant',
                   content    => $choice->{content} // '',
                   tool_calls => $choice->{tool_calls} // []
               });
           } else {
               my $err_msg = $tx->error ? $tx->error->{message} : "Unknown Connection Error";
               $promise->reject("Gemini API Error: " . $err_msg);
           }
       });

   } else {
       $promise->reject("Interface not supported: $service");
   }

   return $promise;
};

# ==========================================
# PROMPT GENERATORS
# ==========================================
sub prompt_for_loading ($filename, $preview) {
   return <<"PROMPT";
You are an expert R developer.
Determine the structure of the dataset file '$filename' from the following preview:

File Preview:
$preview

Write a simple R script to load this file into a data frame named 'df'. Use base R or readr.
Ensure that the separator and decimal markers are correct.

Return ONLY the raw executable R code to load the file. No commentary, no markdown.
PROMPT
}

# ==========================================
# HELPER: Safe R Code Execution
# ==========================================
helper execute_r => sub ($c, $code, $workdir) {
   my ($fh, $temp_file) = tempfile(DIR => $workdir, SUFFIX => '.R', UNLINK => 1);
   binmode($fh, ':utf8');
   print $fh $code;
   close $fh;

   my $filename = basename($temp_file);
   my $R = Statistics::R->new(shared => 0);
   $R->startR;

   my ($out, $err);
   
   # eval catches any fatal Perl exceptions thrown by Statistics::R when an R script fails
   eval {
       $R->run(qq{setwd("$workdir")});
       $R->run(qq{source("$filename", encoding = "UTF-8", echo = FALSE, print.eval = TRUE)});
       $err = $R->error;
       $out = $R->read;
   };
   if ($@) {
       $err //= $@;
   }

   $R->stopR;
   unlink($temp_file) if -e $temp_file;

   $out = Encode::decode_utf8($out) if defined $out;
   $err = Encode::decode_utf8($err) if defined $err;

   return ($out, $err);
};

# ==========================================
# HELPER: Session State Management
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
# RECURSIVE AGENT TOOL CALLING LOOP
# ==========================================
sub run_agent_tool_loop ($c, $messages, $session, $llm_config, $step) {
    if ($step >= 4) {
        return Mojo::Promise->resolve({
            output   => "Maximum analysis steps reached.",
            attempts => $step
        });
    }

    return $c->call_chat_llm($messages, \@available_tools, $llm_config)->then(sub ($response) {
        my $tool_calls = $response->{tool_calls};

        if ($tool_calls && @$tool_calls) {
            my $tool_call = $tool_calls->[0];
            my $func_name = $tool_call->{function}{name};
            my $args      = $tool_call->{function}{arguments};

            if (!ref $args) {
                $args = eval { decode_json($args) } // {};
            }

            if ($func_name eq 'execute_r_code') {
                my $code = $args->{code};
                $c->app->log->info("[Agent] Executing R Code (Step $step):\n$code");

                # Prepend dataset loader so 'df' is available in the new R session
                my $full_code = ($session->{loader_code} // "") . "\n\n" . $code;

                my ($out, $err) = $c->execute_r($full_code, $session->{workdir});
                my $result_text;

                if ($err) {
                    $result_text = "R Error during execution:\n$err";
                    $c->app->log->warn("[Agent] R execution error received.");
                } else {
                    $result_text = "Execution successful.\nOutput:\n$out";
                    $session->{r_code} .= "\n\n# --- Step $step ---\n" . $code;
                }

                push @$messages, $response;
                push @$messages, {
                    role         => 'tool',
                    name         => 'execute_r_code',
                    content      => $result_text,
                    tool_call_id => $tool_call->{id} // 'call_id'
                };

                return run_agent_tool_loop($c, $messages, $session, $llm_config, $step + 1);
            } else {
                push @$messages, $response;
                push @$messages, {
                    role         => 'tool',
                    name         => $func_name,
                    content      => "Error: Unknown tool '$func_name'.",
                    tool_call_id => $tool_call->{id} // 'call_id'
                };
                return run_agent_tool_loop($c, $messages, $session, $llm_config, $step + 1);
            }
        } else {
            push @$messages, $response;
            return Mojo::Promise->resolve({
                output   => $response->{content},
                attempts => $step
            });
        }
    });
}

# ==========================================
# ROUTES (API)
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

   my $first_500_bytes = "[No preview available]";
   if (-T $filepath) {
       open my $fh, '<', $filepath or return $c->render(json => {error => "Cannot read file: $!"});
       read($fh, $first_500_bytes, 500);
       close $fh;
       $first_500_bytes = Encode::decode_utf8($first_500_bytes);
   }

   my $prompt = prompt_for_loading($filename, $first_500_bytes);

   $c->render_later;
   $c->inactivity_timeout(120);

   $c->call_chat_llm([{ role => 'user', content => $prompt }], undef, $llm_config)->then(sub ($response) {
       my $r_code = $response->{content};
       $r_code =~ s/^```[rR]?\s*//gm;
       $r_code =~ s/```$//gm;

       my $loader_code = $r_code;

       $r_code .= "\noptions(width=1000)\nprint('---SUMMARY START---')\ncat('--- STRUCTURE ---\\n')\nstr(df)\ncat('\\n--- SUMMARY ---\\n')\nsummary(df)\n";

       my ($out, $err) = $c->execute_r($r_code, $workdir);
       if ($err) {
           return $c->render(json => {error => "R Loading Error", r_err => $err, code => $r_code});
       }

       my $summary = $out;
       $summary =~ s/.*---SUMMARY START---(?:\r?\n)?//s;

       my @history = (
           {
               role    => 'system',
               content => "You are an expert statistical assistant. The user uploaded a dataset named '$filename'. "
                        . "A data frame named 'df' has already been loaded for you in R.\n\n"
                        . "Strict Formatting Guidelines:\n"
                        . "1. NEVER use LaTeX math delimiters like '\$' or '\$\$' in your chat responses.\n"
                        . "2. NEVER use LaTeX commands like '\\times', '\\frac', '\\cdot', etc.\n"
                        . "3. Always write formulas and calculations in clean, readable plain Unicode text (e.g., use '×' instead of '\\times' or '*', and use '=' instead of math blocks).\n"
                        . "   Example: '5! = 5 × 4 × 3 × 2 × 1 = 120'.\n"
                        . "4. Present statistical outputs and equations clearly with linebreaks and indentation.\n\n"
                        . "Execution Guidelines:\n"
                        . "1. Whenever you need to perform calculations, run statistical tests, or generate plots, you MUST use the 'execute_r_code' tool.\n"
                        . "2. Do not write raw markdown code blocks in your chat response; always use the tool instead.\n"
                        . "3. Always verify your results and explain them clearly to the user."
           },
           {
               role    => 'assistant',
               content => "Dataset loaded successfully. Here is the summary:\n\n" . $summary
           }
       );

       my $session = {
           workdir     => $workdir,
           filename    => $filename,
           loader_code => $loader_code,
           r_code      => $r_code,
           summary     => $summary,
           history     => \@history
       };
       $c->save_session_data($session_id, $session);

       $c->render(json => {
           session_id => $session_id,
           summary    => $summary,
           r_code     => $r_code
       });
   })->catch(sub ($err) {
       warn $err;
       $c->render(json => {error => "LLM service error on load: $err"}, status => 500);
   });
};

post '/api/chat' => sub ($c) {
   my $payload    = $c->req->json;
   my $session_id = $payload->{session_id};
   $session_id =~ s/[^a-zA-Z0-9_\-]//g if defined $session_id;

   my $user_input = $payload->{prompt};
   my $llm_config = $payload->{llm_config} // {};

   my $session = $c->load_session_data($session_id);
   return $c->render(json => {error => 'Session not found'}) unless $session;

   $c->render_later;
   $c->inactivity_timeout(120);

   # 1. Map directory contents BEFORE agent execution
   opendir(my $dh_before, $session->{workdir});
   my %files_before = map { $_ => 1 } readdir($dh_before);
   closedir($dh_before);

   my $messages = $session->{history} // [];
   push @$messages, { role => 'user', content => $user_input };

   run_agent_tool_loop($c, $messages, $session, $llm_config, 1)->then(sub ($result) {
       
       $session->{history} = $messages;
       $c->save_session_data($session_id, $session);

       # 2. Map directory contents AFTER agent execution
       opendir(my $dh_after, $session->{workdir});
       my @all_files = readdir($dh_after);
       closedir($dh_after);

       # Filter out files that already existed in previous rounds
       my @new_files = grep { !$files_before{$_} } @all_files;

       my @png_files = grep { !/^\./ && $_ ne $session->{filename} && $_ =~ /\.(?:png|jpe?g|gif|svg)$/i } @new_files;
       
       # Filter out Rplots.pdf (R's automatic headless graphics output artifact)
       my @pdf_files = grep { !/^\./ && $_ ne $session->{filename} && $_ ne 'Rplots.pdf' && $_ =~ /\.pdf$/i } @new_files;

       my @thumbnails = map { "/api/download/file/$session_id/$_" } @png_files;
       my @pdf_urls   = map { "/api/download/file/$session_id/$_" } @pdf_files;
       my @downloads  = @pdf_urls ? @pdf_urls : @thumbnails;

       $c->render(json => {
           success    => \1,
           output     => $result->{output},
           attempts   => $result->{attempts},
           downloads  => \@downloads,
           thumbnails => \@thumbnails
       });

   })->catch(sub ($err) {
       warn $err;
       $c->render(json => {error => "Agentic workflow error", details => "$err"}, status => 500);
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

   if ($c->param('pdf') && $filename =~ /\.png$/i) {
       my $pdf_filename = $filename;
       $pdf_filename =~ s/\.png$/\.pdf/i;
       if (-e "$session->{workdir}/$pdf_filename") {
           $filename = $pdf_filename;
       }
   }

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

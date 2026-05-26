@import <AppKit/AppKit.j>
@import <Foundation/CPObject.j>

// Falls das Backend auf einem anderen Port läuft, hier die URL eintragen (z. B. @"http://localhost:3039")
var BackendBaseURL = @"";

@implementation AppController : CPObject
{
    CPWindow            _mainWindow;
    CPTextView          _summaryTextView;
    CPScrollView        _summaryScrollView;
    
    CPScrollView        _chatScrollView;
    CPView              _chatDocumentView;
    CPTextField         _chatInputField;
    CPButton            _chatSendButton;
    
    CPButton            _newSessionButton;
    CPButton            _downloadScriptButton;
    CPButton            _uploadFileButton;
    CPButton            _settingsButton;
    
    CPProgressIndicator _progressBar;
    CPTextField         _statusLabel;

    // Einstellungsfenster (Settings Sheet)
    CPWindow            _settingsWindow;
    CPPopUpButton       _servicePopUp;
    CPTextField         _endpointField;
    CPTextField         _modelField;
    CPTextField         _apiKeyField;

    CPString            _currentSessionId;
    float               _currentChatY;
}

- (void)applicationDidFinishLaunching:(CPNotification)aNotification
{
    // Systemmenü konfigurieren
    var mainMenu = [CPApp mainMenu];
    while ([mainMenu numberOfItems] > 0)
       [mainMenu removeItemAtIndex:0];

    var appItem = [mainMenu insertItemWithTitle:@"LLMDataAnalyst" action:nil keyEquivalent:nil atIndex:0];
    var appMenu = [[CPMenu alloc] initWithTitle:@"LLMDataAnalyst"];
    [appMenu addItemWithTitle:@"Einstellungen..." action:@selector(openSettingsSheet:) keyEquivalent:@","];
    [appMenu addItemWithTitle:@"Neue Sitzung" action:@selector(newSessionAction:) keyEquivalent:@"n"];
    [mainMenu setSubmenu:appMenu forItem:appItem];
    [CPMenu setMenuBarVisible:YES];

    // Standard-Benutzerdaten initialisieren
    var defaults = [CPUserDefaults standardUserDefaults];
    var defaultSettings = [CPDictionary dictionaryWithObjects:[
        @"ollama",
        @"http://localhost:11434/api/generate",
        @"llama3",
        @"",
        @"llama3-8b-8192",
        @"",
        @"gemini-2.0-flash",
        @"",
        @"google/gemini-2.0-flash-001"
    ] forKeys:[
        @"LLMServiceType",
        @"LLMOllamaEndpoint",
        @"LLMOllamaModel",
        @"LLMGroqAPIKey",
        @"LLMGroqModel",
        @"LLMGeminiAPIKey",
        @"LLMGeminiModel",
        @"LLMOpenRouterAPIKey",
        @"LLMOpenRouterModel"
    ]];
    [defaults registerDefaults:defaultSettings];

    // Hauptfenster im klassischen hellen Cappuccino-Stil erstellen
    _mainWindow = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 1150, 780) styleMask:CPBorderlessBridgeWindowMask];
    [_mainWindow setTitle:@"LLMDataAnalyst - R-Statistik-Assistent"];
    [_mainWindow center];

    var contentView = [_mainWindow contentView];
    var bounds = [contentView bounds];

    // --- OBERE AKTIONSLEISTE ---
    var topBar = [[CPView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(bounds), 60)];
    [topBar setAutoresizingMask:CPViewWidthSizable | CPViewMaxYMargin];
    [topBar setBackgroundColor:[CPColor colorWithWhite:0.95 alpha:1.0]];
    [contentView addSubview:topBar];

    // Titelbeschriftung
    var titleLabel = [[CPTextField alloc] initWithFrame:CGRectMake(20, 15, 250, 30)];
    [titleLabel setStringValue:@"LLMDataAnalyst"];
    [titleLabel setTextColor:[CPColor blackColor]];
    [titleLabel setFont:[CPFont boldSystemFontOfSize:18.0]];
    [topBar addSubview:titleLabel];

    // Einstellungs-Button
    _settingsButton = [[CPButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(bounds) - 480, 17, 130, 26)];
    [_settingsButton setTitle:@"Einstellungen..."];
    [_settingsButton setAutoresizingMask:CPViewMinXMargin];
    [_settingsButton setTarget:self];
    [_settingsButton setAction:@selector(openSettingsSheet:)];
    [topBar addSubview:_settingsButton];

    // Neue Sitzung Button
    _newSessionButton = [[CPButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(bounds) - 340, 17, 130, 26)];
    [_newSessionButton setTitle:@"Neue Sitzung"];
    [_newSessionButton setAutoresizingMask:CPViewMinXMargin];
    [_newSessionButton setTarget:self];
    [_newSessionButton setAction:@selector(newSessionAction:)];
    [topBar addSubview:_newSessionButton];

    // R-Code Herunterladen Button
    _downloadScriptButton = [[CPButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(bounds) - 190, 17, 170, 26)];
    [_downloadScriptButton setTitle:@"R-Code herunterladen"];
    [_downloadScriptButton setAutoresizingMask:CPViewMinXMargin];
    [_downloadScriptButton setTarget:self];
    [_downloadScriptButton setAction:@selector(downloadScriptAction:)];
    [_downloadScriptButton setEnabled:NO];
    [topBar addSubview:_downloadScriptButton];

    // --- SPLIT-VIEW ARBEITSBEREICH ---
    var splitHeight = CGRectGetHeight(bounds) - 60;
    var splitView = [[CPSplitView alloc] initWithFrame:CGRectMake(0, 60, CGRectGetWidth(bounds), splitHeight)];
    [splitView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [splitView setVertical:YES];

    var dividerWidth = [splitView dividerThickness];
    var leftWidth = (CGRectGetWidth([splitView bounds]) - dividerWidth) * 0.35;
    var rightWidth = (CGRectGetWidth([splitView bounds]) - dividerWidth) - leftWidth;

    // LINKS: Datei-Upload und Konsolen-Ansicht
    var leftContainer = [[CPView alloc] initWithFrame:CGRectMake(0, 0, leftWidth, splitHeight)];
    [leftContainer setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [leftContainer setBackgroundColor:[CPColor colorWithWhite:0.97 alpha:1.0]];

    var panelHeader = [[CPView alloc] initWithFrame:CGRectMake(0, 0, leftWidth, 110)];
    [panelHeader setAutoresizingMask:CPViewWidthSizable | CPViewMaxYMargin];
    [panelHeader setBackgroundColor:[CPColor colorWithWhite:0.90 alpha:1.0]];
    [leftContainer addSubview:panelHeader];

    _uploadFileButton = [[CPButton alloc] initWithFrame:CGRectMake(15, 15, leftWidth - 30, 40)];
    [_uploadFileButton setTitle:@"Datei hochladen"];
    [_uploadFileButton setAutoresizingMask:CPViewWidthSizable];
    [_uploadFileButton setTarget:self];
    [_uploadFileButton setAction:@selector(triggerNativeUploadAction:)];
    [panelHeader addSubview:_uploadFileButton];

    _statusLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 65, leftWidth - 30, 35)];
    [_statusLabel setStringValue:@"Warte auf Datei-Upload."];
    [_statusLabel setTextColor:[CPColor colorWithWhite:0.3 alpha:1.0]];
    [_statusLabel setFont:[CPFont systemFontOfSize:11.0]];
    [_statusLabel setLineBreakMode:CPLineBreakByWordWrapping];
    [_statusLabel setAutoresizingMask:CPViewWidthSizable];
    [panelHeader addSubview:_statusLabel];

    // Konsolen-Fenster (Klassische Text-Präsentationsbox)
    _summaryScrollView = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 110, leftWidth, splitHeight - 110)];
    [_summaryScrollView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [_summaryScrollView setAutohidesScrollers:YES];
    [_summaryScrollView setHasHorizontalScroller:YES];

    _summaryTextView = [[CPTextView alloc] initWithFrame:[_summaryScrollView bounds]];
    [_summaryTextView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [_summaryTextView setMinSize:CGSizeMake(0, 0)];
    [_summaryTextView setMaxSize:CGSizeMake(100000, 100000)];
    [_summaryTextView setHorizontallyResizable:YES];
    [_summaryTextView setVerticallyResizable:YES];
    [_summaryTextView setRichText:NO];
    [_summaryTextView setEditable:NO];
    [_summaryTextView setBackgroundColor:[CPColor colorWithWhite:0.98 alpha:1.0]];
    [_summaryTextView setTextColor:[CPColor blackColor]];
    
    // Monospaced System-Schriftart setzen
    [_summaryTextView setFont:[CPFont fontWithName:@"Courier" size:8.0]];
    [_summaryTextView setString:@"Bitte laden Sie einen Datensatz (CSV/Excel) hoch."];

    [_summaryScrollView setDocumentView:_summaryTextView];
    [leftContainer addSubview:_summaryScrollView];
    [splitView addSubview:leftContainer];

    // RECHTS: Verlauf und Chat-Eingabe
    var rightContainer = [[CPView alloc] initWithFrame:CGRectMake(0, 0, rightWidth, splitHeight)];
    [rightContainer setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [rightContainer setBackgroundColor:[CPColor colorWithWhite:0.95 alpha:1.0]];

    var chatScrollHeight = splitHeight - 75;
    _chatScrollView = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, rightWidth, chatScrollHeight)];
    [_chatScrollView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [_chatScrollView setAutohidesScrollers:YES];
    [_chatScrollView setHasHorizontalScroller:NO];
    [_chatScrollView setBackgroundColor:[CPColor whiteColor]];

    _chatDocumentView = [[CPView alloc] initWithFrame:CGRectMake(0, 0, rightWidth, chatScrollHeight)];
    [_chatDocumentView setAutoresizingMask:CPViewWidthSizable];
    [_chatScrollView setDocumentView:_chatDocumentView];
    [rightContainer addSubview:_chatScrollView];

    // Untere Eingabeleiste
    var inputContainer = [[CPView alloc] initWithFrame:CGRectMake(0, chatScrollHeight, rightWidth, 75)];
    [inputContainer setAutoresizingMask:CPViewWidthSizable | CPViewMinYMargin];
    [inputContainer setBackgroundColor:[CPColor colorWithWhite:0.92 alpha:1.0]];
    [rightContainer addSubview:inputContainer];

    _chatInputField = [[CPTextField alloc] initWithFrame:CGRectMake(15, 18, rightWidth - 145, 38)];
    [_chatInputField setAutoresizingMask:CPViewWidthSizable];
    [_chatInputField setEditable:YES];
    [_chatInputField setBezeled:YES];
    [_chatInputField setFont:[CPFont systemFontOfSize:13.0]];
    [_chatInputField setTextColor:[CPColor blackColor]];
    [_chatInputField setPlaceholderString:@"Warte auf Datei-Upload..."];
    [_chatInputField setEnabled:NO];
    [_chatInputField setTarget:self];
    [_chatInputField setAction:@selector(submitChatAction:)];
    [inputContainer addSubview:_chatInputField];

    _chatSendButton = [[CPButton alloc] initWithFrame:CGRectMake(rightWidth - 120, 18, 105, 38)];
    [_chatSendButton setTitle:@"Senden"];
    [_chatSendButton setAutoresizingMask:CPViewMinXMargin];
    [_chatSendButton setEnabled:NO];
    [_chatSendButton setTarget:self];
    [_chatSendButton setAction:@selector(submitChatAction:)];
    [inputContainer addSubview:_chatSendButton];

    // Fortschrittsanzeige
    _progressBar = [[CPProgressIndicator alloc] initWithFrame:CGRectMake(CGRectGetWidth(bounds) - 660, 23, 150, 14)];
    [_progressBar setStyle:CPProgressIndicatorBarStyle];
    [_progressBar setIndeterminate:YES];
    [_progressBar setHidden:YES];
    [topBar addSubview:_progressBar];

    [splitView addSubview:rightContainer];
    [contentView addSubview:splitView];

    [_mainWindow orderFront:self];
    [self initializeNewSessionOnClient];
}

// --- CONFIGURATION SHEET ---

- (void)openSettingsSheet:(id)sender
{
    if (!_settingsWindow)
    {
        _settingsWindow = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 480, 260)
                                                      styleMask:CPTitledWindowMask | CPClosableWindowMask];
        
        var sheetContentView = [_settingsWindow contentView];
        var sheetBounds = [sheetContentView bounds];

        var serviceLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 25, 110, 20)];
        [serviceLabel setStringValue:@"Schnittstelle:"];
        [serviceLabel setFont:[CPFont systemFontOfSize:12.0]];
        [serviceLabel setAlignment:CPRightTextAlignment];
        [sheetContentView addSubview:serviceLabel];

        _servicePopUp = [[CPPopUpButton alloc] initWithFrame:CGRectMake(135, 22, 180, 26) pullsDown:NO];
        [_servicePopUp addItemWithTitle:@"Ollama (Lokal)"];
        [[_servicePopUp lastItem] setRepresentedObject:@"ollama"];
        [_servicePopUp addItemWithTitle:@"Groq API"];
        [[_servicePopUp lastItem] setRepresentedObject:@"groq"];
        [_servicePopUp addItemWithTitle:@"Google Gemini"];
        [[_servicePopUp lastItem] setRepresentedObject:@"gemini"];
        [_servicePopUp addItemWithTitle:@"OpenRouter"];
        [[_servicePopUp lastItem] setRepresentedObject:@"openrouter"];
        [_servicePopUp setTarget:self];
        [_servicePopUp setAction:@selector(serviceTypeDidChange:)];
        [sheetContentView addSubview:_servicePopUp];

        var endpointLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 65, 110, 20)];
        [endpointLabel setStringValue:@"Schnittstellen-URL:"];
        [endpointLabel setFont:[CPFont systemFontOfSize:12.0]];
        [endpointLabel setAlignment:CPRightTextAlignment];
        [sheetContentView addSubview:endpointLabel];

        _endpointField = [[CPTextField alloc] initWithFrame:CGRectMake(135, 62, CGRectGetWidth(sheetBounds) - 155, 24)];
        [_endpointField setEditable:YES];
        [_endpointField setBezeled:YES];
        [_endpointField setFont:[CPFont systemFontOfSize:12.0]];
        [sheetContentView addSubview:_endpointField];

        var modelLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 105, 110, 20)];
        [modelLabel setStringValue:@"Modellname:"];
        [modelLabel setFont:[CPFont systemFontOfSize:12.0]];
        [modelLabel setAlignment:CPRightTextAlignment];
        [sheetContentView addSubview:modelLabel];

        _modelField = [[CPTextField alloc] initWithFrame:CGRectMake(135, 102, CGRectGetWidth(sheetBounds) - 155, 24)];
        [_modelField setEditable:YES];
        [_modelField setBezeled:YES];
        [_modelField setFont:[CPFont systemFontOfSize:12.0]];
        [sheetContentView addSubview:_modelField];

        var apiKeyLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 145, 110, 20)];
        [apiKeyLabel setStringValue:@"API-Schlüssel:"];
        [apiKeyLabel setFont:[CPFont systemFontOfSize:12.0]];
        [apiKeyLabel setAlignment:CPRightTextAlignment];
        [sheetContentView addSubview:apiKeyLabel];

        _apiKeyField = [[CPTextField alloc] initWithFrame:CGRectMake(135, 142, CGRectGetWidth(sheetBounds) - 155, 24)];
        [_apiKeyField setEditable:YES];
        [_apiKeyField setBezeled:YES];
        [_apiKeyField setSecure:YES];
        [_apiKeyField setFont:[CPFont systemFontOfSize:12.0]];
        [sheetContentView addSubview:_apiKeyField];

        var btnY = CGRectGetHeight(sheetBounds) - 45;

        var cancelBtn = [[CPButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(sheetBounds) - 205, btnY, 90, 26)];
        [cancelBtn setTitle:@"Abbrechen"];
        [cancelBtn setTarget:self];
        [cancelBtn setAction:@selector(closeSettingsSheet:)];
        [sheetContentView addSubview:cancelBtn];

        var saveBtn = [[CPButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(sheetBounds) - 105, btnY, 90, 26)];
        [saveBtn setTitle:@"Speichern"];
        [saveBtn setTarget:self];
        [saveBtn setAction:@selector(saveSettings:)];
        [sheetContentView addSubview:saveBtn];
    }

    [_settingsWindow setTitle:@"Schnittstellen-Konfiguration"];
    
    // Gespeicherte Konfiguration laden
    var defaults = [CPUserDefaults standardUserDefaults];
    var activeService = [defaults objectForKey:@"LLMServiceType"] || @"ollama";

    if (activeService === @"ollama") [_servicePopUp selectItemAtIndex:0];
    else if (activeService === @"groq") [_servicePopUp selectItemAtIndex:1];
    else if (activeService === @"gemini") [_servicePopUp selectItemAtIndex:2];
    else if (activeService === @"openrouter") [_servicePopUp selectItemAtIndex:3];

    [self updateFieldsForService:activeService];

    [CPApp beginSheet:_settingsWindow
        modalForWindow:_mainWindow
         modalDelegate:self
        didEndSelector:nil
           contextInfo:nil];
}

- (void)updateFieldsForService:(CPString)serviceType
{
    var defaults = [CPUserDefaults standardUserDefaults];

    if (serviceType === @"ollama") {
        [_endpointField setEnabled:YES];
        [_endpointField setStringValue:[defaults objectForKey:@"LLMOllamaEndpoint"] || @"http://localhost:11434/api/generate"];
        [_modelField setStringValue:[defaults objectForKey:@"LLMOllamaModel"] || @"llama3"];
        [_apiKeyField setEnabled:NO];
        [_apiKeyField setStringValue:@""];
        [_apiKeyField setPlaceholderString:@"Nicht erforderlich"];
    } else {
        [_endpointField setEnabled:NO];
        [_endpointField setStringValue:@""];
        [_endpointField setPlaceholderString:@"Vordefinierte Server-URL"];
        [_apiKeyField setEnabled:YES];
        [_apiKeyField setPlaceholderString:@"API-Schlüssel eingeben"];
        
        if (serviceType === @"groq") {
            [_modelField setStringValue:[defaults objectForKey:@"LLMGroqModel"] || @"llama3-8b-8192"];
            [_apiKeyField setStringValue:[defaults objectForKey:@"LLMGroqAPIKey"] || @""];
        } else if (serviceType === @"gemini") {
            [_modelField setStringValue:[defaults objectForKey:@"LLMGeminiModel"] || @"gemini-2.0-flash"];
            [_apiKeyField setStringValue:[defaults objectForKey:@"LLMGeminiAPIKey"] || @""];
        } else if (serviceType === @"openrouter") {
            [_modelField setStringValue:[defaults objectForKey:@"LLMOpenRouterModel"] || @"google/gemini-2.0-flash-001"];
            [_apiKeyField setStringValue:[defaults objectForKey:@"LLMOpenRouterAPIKey"] || @""];
        }
    }
}

- (void)serviceTypeDidChange:(id)sender
{
    var newService = [[_servicePopUp selectedItem] representedObject];
    [self updateFieldsForService:newService];
}

- (void)closeSettingsSheet:(id)sender
{
    [CPApp endSheet:_settingsWindow];
    [_settingsWindow orderOut:self];
}

- (void)saveSettings:(id)sender
{
    var defaults = [CPUserDefaults standardUserDefaults];
    var activeService = [[_servicePopUp selectedItem] representedObject] || @"ollama";
    
    [defaults setObject:activeService forKey:@"LLMServiceType"];

    if (activeService === @"ollama") {
        [defaults setObject:[_endpointField stringValue] forKey:@"LLMOllamaEndpoint"];
        [defaults setObject:[_modelField stringValue] forKey:@"LLMOllamaModel"];
    } else if (activeService === @"groq") {
        [defaults setObject:[_modelField stringValue] forKey:@"LLMGroqModel"];
        [defaults setObject:[_apiKeyField stringValue] forKey:@"LLMGroqAPIKey"];
    } else if (activeService === @"gemini") {
        [defaults setObject:[_modelField stringValue] forKey:@"LLMGeminiModel"];
        [defaults setObject:[_apiKeyField stringValue] forKey:@"LLMGeminiAPIKey"];
    } else if (activeService === @"openrouter") {
        [defaults setObject:[_modelField stringValue] forKey:@"LLMOpenRouterModel"];
        [defaults setObject:[_apiKeyField stringValue] forKey:@"LLMOpenRouterAPIKey"];
    }

    [self closeSettingsSheet:sender];
    [_statusLabel setStringValue:@"Einstellungen gespeichert."];
}

// --- CLIENT-SEITIGES MODEL FÜR PAYLOADS ---

- (CPDictionary)currentLLMConfigPayload
{
    var defaults = [CPUserDefaults standardUserDefaults];
    var activeService = [defaults objectForKey:@"LLMServiceType"] || @"ollama";
    
    var config = [CPMutableDictionary dictionary];
    [config setObject:activeService forKey:@"service"];

    if (activeService === @"ollama") {
        [config setObject:([defaults objectForKey:@"LLMOllamaEndpoint"] || @"") forKey:@"endpoint"];
        [config setObject:([defaults objectForKey:@"LLMOllamaModel"] || @"") forKey:@"model"];
        [config setObject:@"" forKey:@"api_key"];
    } else if (activeService === @"groq") {
        [config setObject:@"" forKey:@"endpoint"];
        [config setObject:([defaults objectForKey:@"LLMGroqModel"] || @"") forKey:@"model"];
        [config setObject:([defaults objectForKey:@"LLMGroqAPIKey"] || @"") forKey:@"api_key"];
    } else if (activeService === @"gemini") {
        [config setObject:@"" forKey:@"endpoint"];
        [config setObject:([defaults objectForKey:@"LLMGeminiModel"] || @"") forKey:@"model"];
        [config setObject:([defaults objectForKey:@"LLMGeminiAPIKey"] || @"") forKey:@"api_key"];
    } else if (activeService === @"openrouter") {
        [config setObject:@"" forKey:@"endpoint"];
        [config setObject:([defaults objectForKey:@"LLMOpenRouterModel"] || @"") forKey:@"model"];
        [config setObject:([defaults objectForKey:@"LLMOpenRouterAPIKey"] || @"") forKey:@"api_key"];
    }

    return config;
}

// --- SESSION ARBEITSABLÄUFE ---

- (void)initializeNewSessionOnClient
{
    var date = new Date().getTime();
    var rand = Math.floor(Math.random() * 1000);
    _currentSessionId = "session_" + date + "_" + rand;

    _currentChatY = 20;
    
    [_summaryTextView setString:@"Bitte laden Sie einen Datensatz hoch."];
    [_chatInputField setEnabled:NO];
    [_chatInputField setPlaceholderString:@"Warte auf Datei-Upload..."];
    [_chatSendButton setEnabled:NO];
    [_downloadScriptButton setEnabled:NO];
    [_statusLabel setStringValue:@"Bereit für Datenimport."];

    [[_chatDocumentView subviews] makeObjectsPerformSelector:@selector(removeFromSuperview)];
    [_chatDocumentView setFrameSize:CGSizeMake(CGRectGetWidth([_chatScrollView bounds]) - 20, CGRectGetHeight([_chatScrollView bounds]))];
    
    [self appendMessageWithSender:@"bot" text:@"Sitzung gestartet. Bitte laden Sie eine Datei hoch." isError:NO downloads:nil];
}

- (void)newSessionAction:(id)sender
{
    [self initializeNewSessionOnClient];
}

// --- NATIVE DATEIÜBERTRAGUNG (HTML5) ---

- (void)triggerNativeUploadAction:(id)sender
{
    var selfRef = self;
    var fileInput = document.createElement('input');
    fileInput.type = 'file';
    fileInput.onchange = function(e) {
        var file = e.target.files[0];
        if (file) {
            [selfRef processUploadWithFile:file];
        }
    };
    fileInput.click();
}

- (void)processUploadWithFile:(id)file
{
    // Scoped Closure-Variablen für asynchronen Kontext sichern
    var progressBar = _progressBar,
        selfRef = self,
        uploadFileButton = _uploadFileButton,
        summaryTextView = _summaryTextView,
        statusLabel = _statusLabel,
        chatInputField = _chatInputField,
        chatSendButton = _chatSendButton,
        downloadScriptButton = _downloadScriptButton;

    [progressBar setHidden:NO];
    [progressBar startAnimation:selfRef];
    [uploadFileButton setEnabled:NO];
    [statusLabel setStringValue:@"Sende Datei an Backend-Dienst..."];

    var uploadUrl = [self backendPath:@"/api/upload"];
    var formData = new FormData();
    formData.append('file', file);
    formData.append('session_id', _currentSessionId);
    
    // Aktuelle LLM-Konfiguration mitsenden
    var configDict = [self currentLLMConfigPayload];
    var configJSObject = {};
    var keys = [configDict allKeys];
    for (var i = 0; i < [keys count]; i++) {
        var k = [keys objectAtIndex:i];
        configJSObject[k] = [configDict objectForKey:k];
    }
    formData.append('llm_config', JSON.stringify(configJSObject));

    fetch(uploadUrl, {
        method: 'POST',
        body: formData
    })
    .then(function(response) {
        if (!response.ok) {
            throw new Error("Fehlerhafter Server-Antwortstatus: " + response.status);
        }
        return response.json();
    })
    .then(function(data) {
        [progressBar stopAnimation:selfRef];
        [progressBar setHidden:YES];
        [uploadFileButton setEnabled:YES];

        if (data.error) {
            [summaryTextView setString:@"Import-Fehler:\n" + data.error];
            [statusLabel setStringValue:@"Upload failed."];
            [selfRef appendMessageWithSender:@"bot" text:@"Fehler beim Laden: " + data.error isError:YES downloads:nil];
            return;
        }

        if (data.session_id) {
            _currentSessionId = data.session_id;
        }

        [summaryTextView setString:(data.summary || "Keine strukturelle Zusammenfassung verfügbar.")];
        [chatInputField setEnabled:YES];
        [chatInputField setPlaceholderString:@"Was soll berechnet oder grafisch aufbereitet werden?"];
        [chatInputField becomeFirstResponder];
        [chatSendButton setEnabled:YES];
        [downloadScriptButton setEnabled:YES];
        [statusLabel setStringValue:@"Datensatz geladen."];

        [selfRef appendMessageWithSender:@"bot" text:@"Datei erfolgreich verarbeitet. Analyse-Sitzung ist bereit." isError:NO downloads:nil];
    })
    .catch(function(error) {
        [progressBar stopAnimation:selfRef];
        [progressBar setHidden:YES];
        [uploadFileButton setEnabled:YES];
        [statusLabel setStringValue:@"Netzwerk-Übertragungsfehler."];
        [selfRef appendMessageWithSender:@"bot" text:@"Kommunikation zum Server fehlgeschlagen: " + error.message isError:YES downloads:nil];
    });
}

// --- CHAT-STEUERUNG ---

- (void)submitChatAction:(id)sender
{
    var prompt = [_chatInputField stringValue];
    if (!prompt || [prompt stringByTrimmingWhitespace] === @"") {
        return;
    }

    // Scoped Closure-Variablen für asynchronen Kontext sichern
    var progressBar = _progressBar,
        selfRef = self,
        chatInputField = _chatInputField,
        chatSendButton = _chatSendButton,
        statusLabel = _statusLabel;

    [chatInputField setStringValue:@""];
    [chatInputField setEnabled:NO];
    [chatSendButton setEnabled:NO];
    [progressBar setHidden:NO];
    [progressBar startAnimation:selfRef];
    [statusLabel setStringValue:@"Anfrage wird verarbeitet..."];

    [self appendMessageWithSender:@"user" text:prompt isError:NO downloads:nil];

    var chatUrl = [self backendPath:@"/api/chat"];
    
    // Aktuelle Konfiguration mitsenden
    var configDict = [self currentLLMConfigPayload];
    var configJSObject = {};
    var keys = [configDict allKeys];
    for (var i = 0; i < [keys count]; i++) {
        var k = [keys objectAtIndex:i];
        configJSObject[k] = [configDict objectForKey:k];
    }

    var payload = {
        "session_id": _currentSessionId,
        "prompt": prompt,
        "llm_config": configJSObject
    };

    fetch(chatUrl, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json'
        },
        body: JSON.stringify(payload)
    })
    .then(function(response) {
        if (!response.ok) {
            throw new Error("Fehler beim Abruf der Server-Ressource.");
        }
        return response.json();
    })
    .then(function(data) {
        [progressBar stopAnimation:selfRef];
        [progressBar setHidden:YES];
        [chatInputField setEnabled:YES];
        [chatInputField becomeFirstResponder];
        [chatSendButton setEnabled:YES];
        [statusLabel setStringValue:@"Antwort empfangen."];

        if (data.error || data.success === false) {
            var errText = data.error || "Unerwarteter Fehler im Backend.";
            if (data.details) errText += "\n\nDetails: " + data.details;
            [selfRef appendMessageWithSender:@"bot" text:@"Fehler:\n" + errText isError:YES downloads:nil];
        } else {
            var msg = "Code erfolgreich ausgeführt (" + data.attempts + " Versuche).";
            if (data.output && (!data.downloads || data.downloads.length === 0)) {
                msg += "\n\nKonsole:\n" + data.output;
            }
            [selfRef appendMessageWithSender:@"bot" text:msg isError:NO downloads:data.downloads];
        }
    })
    .catch(function(error) {
        [progressBar stopAnimation:selfRef];
        [progressBar setHidden:YES];
        [chatInputField setEnabled:YES];
        [chatInputField becomeFirstResponder];
        [chatSendButton setEnabled:YES];
        [statusLabel setStringValue:@"Verarbeitungsfehler."];
        [selfRef appendMessageWithSender:@"bot" text:@"Fehler bei der Kommunikation: " + error.message isError:YES downloads:nil];
    });
}

// --- DYNAMISCHER CHAT-FEED ---

- (void)appendMessageWithSender:(CPString)sender text:(CPString)text isError:(BOOL)isError downloads:(CPArray)downloads
{
    var docWidth = CGRectGetWidth([_chatScrollView bounds]) - 30;
    
    var lines = Math.ceil(text.length / (docWidth / 7.5));
    var textHeight = Math.max(25, lines * 18);
    var cardHeight = textHeight + 40;
    
    var hasImages = NO;
    var imageCount = 0;
    if (downloads && [downloads count] > 0) {
        for (var i = 0; i < [downloads count]; i++) {
            var fileUrl = downloads[i];
            if ([self isImagePath:fileUrl]) {
                hasImages = YES;
                imageCount++;
            } else {
                cardHeight += 45;
            }
        }
    }
    
    if (hasImages) {
        cardHeight += (imageCount * 280);
    }

    var cardBox = [[CPBox alloc] initWithFrame:CGRectMake(15, _currentChatY, docWidth, cardHeight)];
    [cardBox setBoxType:CPBoxCustom];
    [cardBox setBorderType:CPLineBorder];
    [cardBox setBorderWidth:1.0];
    [cardBox setBorderColor:[CPColor colorWithWhite:0.8 alpha:1.0]];
    [cardBox setCornerRadius:6.0];
    [cardBox setAutoresizingMask:CPViewWidthSizable];

    if ([sender isEqualToString:@"user"]) {
        [cardBox setFillColor:[CPColor colorWithRed:0.90 green:0.93 blue:1.0 alpha:1.0]];
        [cardBox setTitle:@"Nutzer"];
    } else {
        if (isError) {
            [cardBox setFillColor:[CPColor colorWithRed:1.0 green:0.90 blue:0.90 alpha:1.0]];
        } else {
            [cardBox setFillColor:[CPColor colorWithWhite:0.96 alpha:1.0]];
        }
        [cardBox setTitle:@"System"];
    }

    var container = [cardBox contentView];
    
    var textLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 10, docWidth - 30, textHeight)];
    [textLabel setStringValue:text];
    [textLabel setTextColor:[CPColor blackColor]];
    [textLabel setFont:[CPFont systemFontOfSize:12.0]];
    [textLabel setLineBreakMode:CPLineBreakByWordWrapping];
    [textLabel setAutoresizingMask:CPViewWidthSizable];
    [container addSubview:textLabel];

    if (downloads && [downloads count] > 0) {
        var runningY = textHeight + 20;
        
        for (var i = 0; i < [downloads count]; i++) {
            var fileUrl = [downloads objectAtIndex:i];
            var resolvedUrl = [self backendPath:fileUrl];
            var filename = [fileUrl lastPathComponent] || "Datei";

            if ([self isImagePath:fileUrl]) {
                var timestamp = new Date().getTime();
                var bustUrl = resolvedUrl + "?t=" + timestamp;

                var imgLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, runningY, docWidth - 30, 20)];
                [imgLabel setStringValue:filename + ":"];
                [imgLabel setTextColor:[CPColor darkGrayColor]];
                [imgLabel setFont:[CPFont boldSystemFontOfSize:11.0]];
                [container addSubview:imgLabel];
                runningY += 22;

                var cpImage = [[CPImage alloc] initWithContentsOfFile:bustUrl];
                var imageView = [[CPImageView alloc] initWithFrame:CGRectMake(15, runningY, docWidth - 30, 220)];
                [imageView setImage:cpImage];
                [imageView setImageScaling:CPScaleProportionallyUpOrDown];
                [imageView setAutoresizingMask:CPViewWidthSizable];
                [imageView setBackgroundColor:[CPColor whiteColor]];
                [container addSubview:imageView];
                runningY += 230;

                var dlPlotButton = [[CPButton alloc] initWithFrame:CGRectMake(15, runningY, 160, 24)];
                [dlPlotButton setTitle:@"Herunterladen"];
                [dlPlotButton setTarget:self];
                [dlPlotButton setAction:@selector(openResourceAction:)];
                dlPlotButton._representedObject = resolvedUrl;
                [container addSubview:dlPlotButton];
                runningY += 35;
            } else {
                var dlFileButton = [[CPButton alloc] initWithFrame:CGRectMake(15, runningY, docWidth - 30, 30)];
                [dlFileButton setTitle:@"Datei herunterladen: " + filename];
                [dlFileButton setTarget:self];
                [dlFileButton setAction:@selector(openResourceAction:)];
                [dlFileButton setAutoresizingMask:CPViewWidthSizable];
                dlFileButton._representedObject = resolvedUrl;
                [container addSubview:dlFileButton];
                
                runningY += 40;
            }
        }
    }

    [_chatDocumentView addSubview:cardBox];
    
    _currentChatY += cardHeight + 15;
    [_chatDocumentView setFrameSize:CGSizeMake(docWidth, _currentChatY + 50)];

    var boundsHeight = CGRectGetHeight([_chatScrollView bounds]);
    if (_currentChatY > boundsHeight) {
        [[_chatScrollView contentView] scrollToPoint:CGPointMake(0, _currentChatY - boundsHeight + 80)];
    }
}

// --- AKTIONEN UND HILFSMETHODEN ---

- (void)downloadScriptAction:(id)sender
{
    if (!_currentSessionId) return;
    var endpoint = @"/api/download/script/" + _currentSessionId;
    window.open([self backendPath:endpoint], '_blank');
}

- (void)openResourceAction:(id)sender
{
    var resourceUrl = sender._representedObject;
    if (resourceUrl) {
        window.open(resourceUrl, '_blank');
    }
}

- (CPString)backendPath:(CPString)path
{
    if ([BackendBaseURL length] > 0 && [path hasPrefix:@"/"]) {
        return BackendBaseURL + path;
    }
    return BackendBaseURL + path;
}

- (BOOL)isImagePath:(CPString)path
{
    var lowercasePath = [path lowercaseString];
    return [lowercasePath hasSuffix:@".png"] || 
           [lowercasePath hasSuffix:@".jpg"] || 
           [lowercasePath hasSuffix:@".jpeg"] || 
           [lowercasePath hasSuffix:@".gif"] || 
           [lowercasePath hasSuffix:@".svg"];
}

@end

# LLMDataAnalyst

LLMDataAnalyst is a self-hosted, web-based statistical data analysis assistant. It pairs a desktop-class web frontend (built with **Objective-J/Cappuccino**) with a lightweight microservice backend (built with **Perl/Mojolicious**) to analyze and visualize datasets using automated R script generation and execution.

The system runs generated R code in isolated, session-specific directories, captures console outputs or generated plots, and handles syntax issues using an automatic self-repair loop before returning feedback to the user.

---
<img width="1088" height="857" alt="Bildschirmfoto 2026-05-26 um 18 16 53" src="https://github.com/user-attachments/assets/f5c2791a-0998-421a-882f-e51f2c2268fc" />

## System Architecture

The application is structured into the following primary components:

```
                                  JSON Requests
 ┌─────────────────────┐  ────────────────────────>  ┌─────────────────────┐
 │ Cappuccino Frontend │                             │   Perl Mojolicious  │
 │ (Desktop-class Web) │  <────────────────────────  │       Backend       │
 └─────────────────────┘         Plots / Data        └─────────────────────┘
                                                        │               │
                                          Prompts /     │               │ R-Code
                                          R-Code        │               │ Execution
                                                        ▼               ▼
                                                 ┌─────────────┐ ┌──────────────┐
                                                 │   LLM API   │ │Local R Engine│
                                                 │  (Cloud or  │ │ (R-Stats &   │
                                                 │   Local)    │ │ Plot Gen)    │
                                                 └─────────────┘ └──────────────┘
```

1. **Frontend (Objective-J / Cappuccino)**:
   * **Structured Dataset Grid**: Parses R's structure output (`str(df)`) and renders variables, data types, and preview rows in a clean `CPTableView` [4].
   * **Drag-and-Drop Ingestion**: Both the main table grid and the upload button accept direct file drops from your operating system, triggering automatic data processing [4].
   * **Custom Vector Speech Bubbles**: The chat window renders speech bubbles and triangular pointing tails as cohesive, single-path canvas vectors (`SpeechBubbleBox`), preventing browser-specific layering and clipping issues [4].
   * **Session Sync & Transfer**: Enables users to export or import their live chat history and state using a single copy-pasteable JSON Transfer Sheet [4].
   * **LLM Provider Configuration**: A settings sheet lets the user configure and switch between local or cloud-based LLM providers.

2. **Backend (Perl / Mojolicious::Lite)**:
   * **Unified Multi-Model Client**: Direct stateless integrations for Ollama (local), Groq, Google Gemini, and OpenRouter. Client credentials and settings are kept in the browser and passed on-demand.
   * **Isolated Workspaces**: Provisions clean, temporary folders for each active session to execute scripts and output visualizations securely.
   * **Error Self-Correction Loop**: If R script execution encounters syntax errors, the backend intercepts the message, prompts the LLM with the error log, and attempts to repair the script in up to 3 iterative cycles before returning the output.
   * **Asset Serving**: Hosts generated analytical scripts (R) and static visualization plots (PNG, SVG, JPG) dynamically.

---

## Prerequisites

### For the Backend & Execution Engine:
* **Perl 5.20+** with the following CPAN modules:
  * `Mojolicious::Lite` [2]
  * `Mojo::UserAgent` [2]
  * `Statistics::R` [2]
  * `Encode`, `File::Temp`, `JSON` [2]
* A valid **R** installation reachable on the system path [2]. It is recommended to pre-install packages such as `ggplot2`, `readr`, and `readxl` within your R environment, as generated R code frequently depends on them.

---

## Installation & Execution

### 1. Set Up R Dependencies
Open your system's R console and ensure the required packages are installed:
```R
install.packages(c("readr", "readxl", "ggplot2"))
```

### 2. Prepare the Application Files
Since the Mojolicious backend serves the frontend static assets, your compiled Cappuccino files must be placed within the `public/` directory of your project workspace:
```
your-project-directory/
├── backend.pl
└── public/
    ├── index.html
    ├── AppController.j
    └── (other Cappuccino framework assets)
```

### 3. Start the Server
Start the development server using Mojolicious's `morbo` [2]. This serves both the API endpoints and the Cappuccino web UI on port `3036`:
```bash
morbo ./backend.pl --listen "http://*:3036"
```

### 4. Access the Application
Open your browser and navigate to:
```
http://localhost:3036
```

---

## Configuring LLM Providers

The **Settings...** dialog inside the web interface allows you to define your active LLM operator. Configuration details are preserved locally in the browser (`CPUserDefaults`) and are transmitted to the backend only during request execution:

* **Ollama (Local)**: Requires your local endpoint URL (Default: `http://localhost:11434/api/generate`) and target model identifier (e.g., `llama3` or `gemma`).
* **Groq API**: Requires your Groq API key and the desired model identifier (e.g., `llama3-8b-8192`).
* **Google Gemini**: Requires your Google Gemini API key; uses `gemini-2.0-flash` by default.
* **OpenRouter**: Accesses various cloud LLM backends using your OpenRouter API key and specific model identifier.

---

## License

This project is licensed under the terms of the MIT License. See the `LICENSE` file for more details.

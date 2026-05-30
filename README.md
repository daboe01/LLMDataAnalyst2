# LLMDataAnalyst

LLMDataAnalyst is a self-hosted, web-based statistical data analysis assistant. It pairs a desktop-class web frontend (built with **Objective-J/Cappuccino**) with a lightweight microservice backend (built with **Perl/Mojolicious**) to analyze and visualize datasets. 

Instead of simple text extraction, the modern backend utilizes **native tool (function) calling** [2]. It runs an agentic, recursive loop to execute dynamically generated R scripts in isolated workspace sessions, inspects outputs or errors, and self-corrects before presenting the final response to the user [2].

---
<img width="1088" height="857" alt="Bildschirmfoto 2026-05-26 um 18 16 53" src="https://github.com/user-attachments/assets/f5c2791a-0998-421a-882f-e51f2c2268fc" />

## System Architecture

The system coordinates the user interface, LLM communication, and local code execution using an event-driven flow:

```
                                  JSON Requests
 ┌─────────────────────┐  ────────────────────────>  ┌─────────────────────┐
 │ Cappuccino Frontend │                             │   Perl Mojolicious  │
 │ (Desktop-class Web) │  <────────────────────────  │       Backend       │
 └─────────────────────┘       Plots / Downloads     └─────────────────────┘
                                                        │               ▲
                                         Tool Schemas / │               │ R-Code Output
                                         Tool Arguments │               │ & Execution
                                                        ▼               ▼
                                                 ┌─────────────┐ ┌──────────────┐
                                                 │   LLM API   │ │Local R Engine│
                                                 │ (Function   │ │ (R-Stats &   │
                                                 │   Calling)  │ │ Plot Gen)    │
                                                 └─────────────┘ └──────────────┘
```

1. **Frontend (Objective-J / Cappuccino)**:
   * **Structured Dataset Grid**: Parses R's structure output (`str(df)`) and renders variables, data types, and preview rows in a clean `CPTableView`.
   * **Drag-and-Drop Ingestion**: Both the main table grid and the upload button accept direct file drops from your operating system, triggering automatic data processing.
   * **Custom Vector Speech Bubbles**: The chat window renders speech bubbles and triangular pointing tails as cohesive, single-path canvas vectors (`SpeechBubbleBox`), preventing browser-specific layering and clipping issues.
   * **Session Sync & Transfer**: Enables users to export or import their live chat history and state using a single copy-pasteable JSON Transfer Sheet.
   * **LLM Provider Configuration**: A settings sheet lets the user configure and switch between local or cloud-based LLM providers.

2. **Backend (Perl / Mojolicious::Lite)**:
   * **Unified Multi-Model Client**: Direct stateless integration with Ollama (local), Groq, Google Gemini (via official OpenAI compatibility interface), and OpenRouter [2]. It formats native tool schemas and manages authorization tokens dynamically based on settings stored in the browser [2].
   * **Native Tool Calling (Function Calling)**: Declares a standardized JSON Schema (`execute_r_code`) to the LLM [2]. The LLM invokes this tool with structured arguments containing the generated R code [2].
   * **Recursive Agentic Loop**: The backend evaluates tool invocations, runs R scripts locally, formats console outputs/errors, feeds them back as standard `tool` roles, and prompts the LLM recursively (up to 4 iterations) until the analysis is complete [2].
   * **Isolated Workspaces**: Provisions clean, temporary folders for each active session to execute scripts and output visualizations securely [2].
   * **Duale Asset Serving**: Automatically detects newly generated visualization artifacts [2]. When a plot is created, the backend serves a web-friendly PNG format for client-side chat rendering alongside a publication-ready vector PDF for download [2].

---

## Tool Calling Specification

The backend registers a single unified execution tool with the LLM [2]:

```json
{
  "type": "function",
  "function": {
    "name": "execute_r_code",
    "description": "Executes R statistical and mathematical code on the loaded dataset. The dataset is already loaded into a dataframe named 'df'...",
    "parameters": {
      "type": "object",
      "properties": {
        "code": {
          "type": "string",
          "description": "The complete and executable R code."
        }
      },
      "required": ["code"]
    }
  }
}
```

### Visualizations Requirement
To ensure high-quality presentation, whenever the LLM generates a visual plot, it must configure the code to output **both** formats in the current workspace directory using matching base names:
* A raster version (e.g., `plot.png`) for high-performance frontend preview [2].
* A vector version (e.g., `plot.pdf`) for professional, scalable downloads [2].

---

## Prerequisites

### For the Backend & Execution Engine:
* **Perl 5.20+** with the following CPAN modules [2]:
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
Start the development server using Mojolicious's development server `morbo` [2]. This serves both the API endpoints and the Cappuccino web UI on port `3036`:
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

The **Settings...** dialog inside the web interface allows you to define your active LLM operator. Configuration details are preserved locally in the browser (`CPUserDefaults`) and are transmitted to the backend only during request execution [2]:

* **Ollama (Local)**: Queries your local endpoint (Default: `http://localhost:11434/api/chat`) and target model identifier (e.g., `llama3` or `qwen2.5-coder`). Built-in compatibility maps tool parameters dynamically [2].
* **Groq API**: Requires your Groq API key and a model supporting tool calls (e.g., `llama3-8b-8192` or `llama-3.1-70b-versatile`) [2].
* **Google Gemini**: Requires your Gemini API key. Calls the official `https://generativelanguage.googleapis.com/v1beta/openai` compatibility route using tool definitions [2]. Uses `gemini-2.5-flash` by default [2].
* **OpenRouter**: Accesses various cloud LLM backends with tool-calling support using your OpenRouter API key and specific model identifier [2].

---

## License

This project is licensed under the terms of the MIT License. See the `LICENSE` file for more details.
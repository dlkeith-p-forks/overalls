interface Mermaid {
  initialize(config: {
    startOnLoad: boolean;
    securityLevel: "strict";
    theme: "dark" | "default" | "base";
    darkMode?: boolean;
    themeVariables?: Record<string, string>;
    suppressErrorRendering: boolean;
    flowchart: {htmlLabels: boolean};
  }): void;
  render(id: string, source: string): Promise<{svg: string}>;
  parse(source: string): Promise<unknown>;
}
declare const mermaid: Mermaid;
export default mermaid;

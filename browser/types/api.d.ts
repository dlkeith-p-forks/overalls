export interface Tab { id?: number; url?: string }
export interface Event<Listener> { addListener(listener: Listener): void }
export interface ExtensionApi {
  runtime: {
    onInstalled: Event<() => void>;
    onStartup: Event<() => void>;
    openOptionsPage(): Promise<void>;
  };
  tabs: {
    query(query: { active?: boolean; currentWindow?: boolean }): Promise<Tab[]>;
    get(id: number): Promise<Tab>;
    create(options: { url: string }): Promise<Tab>;
    onActivated: Event<(info: { tabId: number }) => void>;
    onUpdated: Event<(id: number, change: { url?: string; status?: string }, tab: Tab) => void>;
  };
  storage: { sync: {
    get(key: string): Promise<Record<string, unknown>>;
    set(value: Record<string, string>): Promise<void>;
  } };
  contextMenus: {
    removeAll(): Promise<void>;
    create(options: { id: string; title: string; contexts: ["action"] }): string | number;
    onClicked: Event<(info: { menuItemId: string | number }) => void>;
  };
  action: {
    setBadgeBackgroundColor(options: { tabId: number; color: string }): Promise<void>;
    setBadgeText(options: { tabId: number; text: string }): Promise<void>;
    setIcon(options: { tabId: number; path: { 16: string; 32: string } }): Promise<void>;
    setTitle(options: { tabId: number; title: string }): Promise<void>;
    enable(id: number): Promise<void>;
    disable(id: number): Promise<void>;
    isEnabled(id: number): Promise<boolean>;
    onClicked: Event<(tab: Tab) => void>;
  };
}
declare global {
  var browser: ExtensionApi | undefined;
  var chrome: ExtensionApi | undefined;
}

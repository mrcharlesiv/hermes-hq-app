// [plugin-pages] Hermes HQ's host for a Hermes dashboard plugin's page (a "page plugin": a plugin whose
// dashboard/manifest.json has a tab). The page's own bundle expects the dashboard's globals, so this file gives it
// the same contract (hermes-agent web/src/plugins/registry.ts exposePluginSDK + plugins/sdk.d.ts, SDK 1.1.0):
// window.__HERMES_PLUGINS__.register(name, Component) and window.__HERMES_PLUGIN_SDK__ with React, hooks, utils, the
// UI components and fetchJSON/authedFetch. The components are HQ's own, styled from the CSS variables the app
// passes in (its palette, light/dark and skin), not the dashboard's look.
//
// Requests: fetchJSON/authedFetch go to the app (WKScriptMessageHandlerWithReply "hq"), which sends them with the
// signed-in gateway's auth (cookies or a Nous bearer) and allows only the plugin's own /api/plugins/<name>/ routes.
// Plugin sockets (buildWsUrl) are not offered yet.
//
// Built by scripts/plugin-host/build.mjs into App/Resources/PluginHost/plugin-host.js (React and ReactDOM included).

import * as React from "react";
import * as ReactDOMClient from "react-dom/client";
import * as ReactDOM from "react-dom";

const { useState, useEffect, useCallback, useMemo, useRef, useContext, createContext } = React;
const page = window.__HQ_PAGE__ || { name: "", label: "", profile: "" };

// MARK: - The app's bridge

function post(message) {
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hq;
  if (!handler) return Promise.reject(new Error("Hermes HQ is not hosting this page."));
  return handler.postMessage(message);
}

function tell(message) {
  try {
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hqNote;
    if (handler) handler.postMessage(message);
  } catch { /* nothing to tell */ }
}

/** The path the app is asked for: a same-page URL ("/api/…" or this page's own origin) as a path with its query. */
export function requestPath(url) {
  const text = String(url == null ? "" : url);
  if (text.startsWith("/")) return text;
  try {
    const parsed = new URL(text, window.location.href);
    if (parsed.origin === window.location.origin) return parsed.pathname + parsed.search;
  } catch { /* fall through */ }
  return text;
}

function bodyText(body) {
  if (body == null) return null;
  if (typeof body === "string") return body;
  if (body instanceof URLSearchParams) return body.toString();
  if (typeof FormData !== "undefined" && body instanceof FormData) {
    throw new Error("Uploads from plugin pages aren’t supported in Hermes HQ yet.");
  }
  if (body instanceof Blob || body instanceof ArrayBuffer || ArrayBuffer.isView(body)) {
    throw new Error("Binary requests from plugin pages aren’t supported in Hermes HQ yet.");
  }
  return String(body);
}

function headerObject(headers) {
  const out = {};
  if (!headers) return out;
  new Headers(headers).forEach((value, key) => { out[key] = value; });
  return out;
}

async function bridgedFetch(url, init) {
  const options = init || {};
  const answer = await post({
    kind: "fetch",
    path: requestPath(url),
    method: String(options.method || "GET").toUpperCase(),
    headers: headerObject(options.headers),
    body: bodyText(options.body),
  });
  if (!answer || typeof answer !== "object") throw new Error("Hermes HQ couldn’t reach Hermes.");
  if (answer.error) {
    const error = new Error(answer.error);
    error.status = answer.status || 0;
    throw error;
  }
  return answer;
}

/** The words fetchJSON throws for a non-2xx answer: the server's `detail` when it sent one. */
export function errorWords(status, text) {
  try {
    const parsed = JSON.parse(text);
    const detail = parsed && (parsed.detail || parsed.error || parsed.message);
    if (typeof detail === "string" && detail) return `${status}: ${detail}`;
  } catch { /* not JSON */ }
  return `${status}: ${text || "Request failed"}`;
}

export async function fetchJSON(url, init) {
  const answer = await bridgedFetch(url, init);
  if (answer.status < 200 || answer.status >= 300) {
    const error = new Error(errorWords(answer.status, answer.body));
    error.status = answer.status;
    error.body = answer.body;
    throw error;
  }
  if (!answer.body) return null;
  return JSON.parse(answer.body);
}

export async function authedFetch(url, init) {
  const answer = await bridgedFetch(url, init);
  return new Response(answer.status === 204 ? null : answer.body, {
    status: answer.status,
    headers: { "content-type": answer.contentType || "application/json" },
  });
}

function socketsUnsupported() {
  return Promise.reject(new Error("Live connections from plugin pages aren’t supported in Hermes HQ yet."));
}

// The dashboard's own API client is not offered: each call says so (plugins use fetchJSON for their routes).
const api = new Proxy({}, {
  get(_target, key) {
    if (typeof key !== "string" || key === "then") return undefined;
    return () => Promise.reject(new Error(`The Hermes dashboard’s ${key}() isn’t available in Hermes HQ.`));
  },
});

// MARK: - Utilities (web/src/lib/utils.ts)

export function cn(...inputs) {
  const out = [];
  const add = (value) => {
    if (!value) return;
    if (typeof value === "string" || typeof value === "number") out.push(String(value));
    else if (Array.isArray(value)) value.forEach(add);
    else if (typeof value === "object") for (const key of Object.keys(value)) if (value[key]) out.push(key);
  };
  inputs.forEach(add);
  return out.join(" ");
}

export function timeAgo(ts) {
  const delta = Date.now() / 1000 - ts;
  if (delta < 60) return "just now";
  if (delta < 3600) return `${Math.floor(delta / 60)}m ago`;
  if (delta < 86400) return `${Math.floor(delta / 3600)}h ago`;
  if (delta < 172800) return "yesterday";
  return `${Math.floor(delta / 86400)}d ago`;
}

export function isoTimeAgo(iso) {
  const delta = (Date.now() - new Date(iso).getTime()) / 1000;
  if (delta < 0 || Number.isNaN(delta)) return "unknown";
  if (delta < 60) return "just now";
  if (delta < 3600) return `${Math.floor(delta / 60)}m ago`;
  if (delta < 86400) return `${Math.floor(delta / 3600)}h ago`;
  return `${Math.floor(delta / 86400)}d ago`;
}

// MARK: - Hooks (@nous-research/ui hooks)

function useToast(duration = 3000) {
  const [toast, setToast] = useState(null);
  const timer = useRef(null);
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);
  const showToast = useCallback((message, type) => {
    if (timer.current) clearTimeout(timer.current);
    setToast({ message, type });
    timer.current = setTimeout(() => setToast(null), duration);
  }, [duration]);
  return { showToast, toast };
}

function useConfirmDelete({ onDelete }) {
  const [pendingId, setPendingId] = useState(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const requestDelete = useCallback((id) => setPendingId(id), []);
  const cancel = useCallback(() => { if (!isDeleting) setPendingId(null); }, [isDeleting]);
  const confirm = useCallback(async () => {
    if (pendingId === null) return;
    setIsDeleting(true);
    try { await onDelete(pendingId); setPendingId(null); } catch { /* the dialog stays open */ } finally { setIsDeleting(false); }
  }, [pendingId, onDelete]);
  return { cancel, confirm, isDeleting, isOpen: pendingId !== null, pendingId, requestDelete };
}

const I18nContext = createContext(null);
function useI18n() {
  const context = useContext(I18nContext);
  if (context) return context;
  const locale = (navigator.language || "en").split("-")[0];
  // The dashboard's `t` is its translation table; plugins read their own strings, so an empty table that answers
  // any key with "" keeps `t.common.save ?? "Save"` working.
  const table = new Proxy({}, { get: (_t, key) => (key === Symbol.toPrimitive ? () => "" : typeof key === "string" ? table : undefined) });
  return { locale, setLocale() {}, t: table };
}

// MARK: - Components (HQ-styled; class names are in the page's stylesheet)

function Card({ className, ...props }) { return <div className={cn("hq-card", className)} {...props} />; }
function CardHeader({ className, ...props }) { return <div className={cn("hq-card-header", className)} {...props} />; }
function CardTitle({ className, ...props }) { return <h3 className={cn("hq-card-title", className)} {...props} />; }
function CardDescription({ className, ...props }) { return <p className={cn("hq-card-description", className)} {...props} />; }
function CardContent({ className, ...props }) { return <div className={cn("hq-card-content", className)} {...props} />; }

function Badge({ className, tone = "default", ...props }) {
  return <span className={cn("hq-badge", `hq-badge-${tone}`, className)} {...props} />;
}

function Button({ className, destructive, ghost, invert, outlined, size, prefix, suffix, type, children, ...props }) {
  const kind = destructive ? (ghost || outlined ? "hq-button-destructive-plain" : "hq-button-destructive")
    : ghost ? "hq-button-ghost" : outlined || invert ? "hq-button-outlined" : "hq-button-filled";
  return (
    <button type={type || "button"} className={cn("hq-button", kind, size ? `hq-button-${size}` : "", className)} {...props}>
      {prefix}{children}{suffix}
    </button>
  );
}

const Input = React.forwardRef(function Input({ className, ...props }, ref) {
  return <input ref={ref} className={cn("hq-input", className)} {...props} />;
});

function Label({ className, ...props }) { return <label className={cn("hq-label", className)} {...props} />; }

function Separator({ className, orientation = "horizontal", ...props }) {
  return <div role="separator" aria-orientation={orientation} className={cn("hq-separator", orientation === "vertical" ? "hq-separator-v" : "", className)} {...props} />;
}

function Checkbox({ className, checked, defaultChecked, onCheckedChange, disabled, id, ...props }) {
  const [own, setOwn] = useState(!!defaultChecked);
  const on = checked === undefined ? own : checked === true;
  return (
    <button type="button" role="checkbox" id={id} aria-checked={checked === "indeterminate" ? "mixed" : on} disabled={disabled}
            data-state={checked === "indeterminate" ? "indeterminate" : on ? "checked" : "unchecked"}
            className={cn("hq-checkbox peer", className)}
            onClick={() => { const next = !on; if (checked === undefined) setOwn(next); onCheckedChange && onCheckedChange(next); }} {...props}>
      {on ? <svg viewBox="0 0 12 12" aria-hidden="true"><path d="M2.5 6.2 5 8.6l4.6-5.2" /></svg> : null}
    </button>
  );
}

function SelectOption() { return null; }

function selectOptions(children) {
  const out = [];
  React.Children.forEach(children, (child) => {
    if (!React.isValidElement(child)) return;
    if (child.props.value !== undefined) {
      out.push({ value: String(child.props.value), label: typeof child.props.children === "string" ? child.props.children : String(child.props.value), disabled: !!child.props.disabled });
    } else if (child.props.children) {
      out.push(...selectOptions(child.props.children));
    }
  });
  return out;
}

// A native <select>: the system's own picker on iPhone and a menu on the Mac.
function Select({ children, className, disabled, id, onValueChange, placeholder, style, value }) {
  const options = useMemo(() => selectOptions(children), [children]);
  const known = options.some((o) => o.value === value);
  return (
    <div className={cn("hq-select", className)} style={style}>
      <select id={id} disabled={disabled} value={known ? value : ""} onChange={(e) => onValueChange && onValueChange(e.target.value)}>
        {!known ? <option value="" disabled>{placeholder || value || ""}</option> : null}
        {options.map((o) => <option key={o.value} value={o.value} disabled={o.disabled}>{o.label}</option>)}
      </select>
      <svg viewBox="0 0 12 12" aria-hidden="true"><path d="M3 4.5 6 7.5l3-3" /></svg>
    </div>
  );
}

function Tabs({ children, className, defaultValue }) {
  const [active, setActive] = useState(defaultValue);
  return <div className={cn("hq-tabs", className)}>{typeof children === "function" ? children(active, setActive) : children}</div>;
}
function TabsList({ className, ...props }) { return <div role="tablist" className={cn("hq-tabs-list", className)} {...props} />; }
function TabsTrigger({ active, className, value: _value, ...props }) {
  return <button type="button" role="tab" aria-selected={!!active} data-state={active ? "active" : "inactive"} className={cn("hq-tabs-trigger", className)} {...props} />;
}

const DialogContext = createContext({ open: false, setOpen() {} });

function Dialog({ open, defaultOpen, onOpenChange, children }) {
  const [own, setOwn] = useState(!!defaultOpen);
  const shown = open === undefined ? own : open;
  const setOpen = useCallback((next) => { if (open === undefined) setOwn(next); onOpenChange && onOpenChange(next); }, [open, onOpenChange]);
  return <DialogContext.Provider value={{ open: shown, setOpen }}>{children}</DialogContext.Provider>;
}

function withClick(child, onClick) {
  return React.cloneElement(child, { onClick: (event) => { child.props.onClick && child.props.onClick(event); if (!event.defaultPrevented) onClick(); } });
}

function DialogTrigger({ asChild, children, ...props }) {
  const { setOpen } = useContext(DialogContext);
  if (asChild && React.isValidElement(children)) return withClick(children, () => setOpen(true));
  return <button type="button" onClick={() => setOpen(true)} {...props}>{children}</button>;
}

function DialogClose({ asChild, children, className, ...props }) {
  const { setOpen } = useContext(DialogContext);
  if (asChild && React.isValidElement(children)) return withClick(children, () => setOpen(false));
  return <button type="button" className={className} onClick={() => setOpen(false)} {...props}>{children}</button>;
}

function Overlay({ onDismiss, children, label }) {
  useEffect(() => {
    const key = (event) => { if (event.key === "Escape") onDismiss(); };
    document.addEventListener("keydown", key);
    return () => document.removeEventListener("keydown", key);
  }, [onDismiss]);
  return ReactDOM.createPortal(
    <div className="hq-overlay" onMouseDown={(event) => { if (event.target === event.currentTarget) onDismiss(); }}>
      <div className="hq-dialog" role="dialog" aria-modal="true" aria-label={label}>{children}</div>
    </div>,
    document.body,
  );
}

function DialogContent({ className, children, showCloseButton = true, onEscapeKeyDown: _esc, onPointerDownOutside: _out, onInteractOutside: _int, ...props }) {
  const { open, setOpen } = useContext(DialogContext);
  if (!open) return null;
  return (
    <Overlay onDismiss={() => setOpen(false)}>
      <div className={cn("hq-dialog-body", className)} {...props}>
        {children}
        {showCloseButton ? (
          <button type="button" className="hq-dialog-x" aria-label="Close" onClick={() => setOpen(false)}>
            <svg viewBox="0 0 12 12" aria-hidden="true"><path d="M3 3l6 6M9 3l-6 6" /></svg>
          </button>
        ) : null}
      </div>
    </Overlay>
  );
}
function DialogHeader({ className, ...props }) { return <div className={cn("hq-dialog-header", className)} {...props} />; }
function DialogFooter({ className, ...props }) { return <div className={cn("hq-dialog-footer", className)} {...props} />; }
function DialogTitle({ className, ...props }) { return <h2 className={cn("hq-dialog-title", className)} {...props} />; }
function DialogDescription({ className, ...props }) { return <p className={cn("hq-dialog-description", className)} {...props} />; }

function ConfirmDialog({ open, title, description, confirmLabel = "Confirm", cancelLabel = "Cancel", destructive, loading, onConfirm, onCancel }) {
  if (!open) return null;
  return (
    <Overlay onDismiss={() => { if (!loading) onCancel(); }} label={title}>
      <div className="hq-dialog-body hq-confirm">
        <h2 className="hq-dialog-title">{title}</h2>
        {description ? <p className="hq-dialog-description">{description}</p> : null}
        <div className="hq-dialog-footer">
          <Button outlined disabled={loading} onClick={onCancel}>{cancelLabel}</Button>
          <Button destructive={destructive} disabled={loading} onClick={onConfirm}>{loading ? "…" : confirmLabel}</Button>
        </div>
      </div>
    </Overlay>
  );
}

function Toast({ toast }) {
  if (!toast) return null;
  return ReactDOM.createPortal(
    <div className={cn("hq-toast", toast.type === "error" ? "hq-toast-error" : "hq-toast-success")} role="status">{toast.message}</div>,
    document.body,
  );
}

function PluginSlot() { return null; }

// MARK: - Registry (web/src/plugins/registry.ts)

const registered = new Map();
const listeners = new Set();
let crashed = false;

function register(name, component) {
  registered.set(name, component);
  listeners.forEach((fn) => { try { fn(); } catch { /* ignore */ } });
}

window.__HERMES_PLUGINS__ = { register, registerSlot() {} };

window.__HERMES_PLUGIN_SDK__ = {
  sdkVersion: "1.1.0",
  React,
  hooks: { useState, useEffect, useCallback, useMemo, useRef, useContext, createContext, useToast, useConfirmDelete },
  api,
  fetchJSON,
  authedFetch,
  buildWsUrl: socketsUnsupported,
  buildWsAuthParam: socketsUnsupported,
  components: {
    Card, CardHeader, CardTitle, CardContent, CardDescription, Badge, Button, Checkbox, ConfirmDialog,
    Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger,
    Input, Label, Select, SelectOption, Separator, Tabs, TabsList, TabsTrigger, Toast, PluginSlot,
  },
  utils: { cn, timeAgo, isoTimeAgo },
  useI18n,
};

// MARK: - The page

class Boundary extends React.Component {
  constructor(props) { super(props); this.state = { error: null }; }
  static getDerivedStateFromError(error) { return { error }; }
  componentDidCatch(error) {
    crashed = true;
    tell({ kind: "state", state: "crashed", message: String((error && error.message) || error).slice(0, 500) });
  }
  render() { return this.state.error ? null : this.props.children; }
}

function Page() {
  const [, setTick] = useState(0);
  useEffect(() => {
    const fn = () => setTick((n) => n + 1);
    listeners.add(fn);
    return () => listeners.delete(fn);
  }, []);
  const Component = registered.get(page.name);
  useEffect(() => { if (Component) tell({ kind: "state", state: "ready" }); }, [Component]);
  if (!Component) return null;
  return <Boundary><Component /></Boundary>;
}

window.addEventListener("error", (event) => {
  if (registered.has(page.name) || crashed) return;
  tell({ kind: "state", state: "script-error", message: String(event.message || "Script error").slice(0, 500) });
});

window.__HQ_HOST__ = {
  /** Called right after the plugin's bundle ran: give an async register a moment, then say it never came. */
  bundleRan() {
    if (registered.has(page.name)) return;
    setTimeout(() => {
      if (!registered.has(page.name)) tell({ kind: "state", state: "unregistered", names: [...registered.keys()].slice(0, 5) });
    }, 4000);
  },
  /** The app's palette changed (light/dark, skin): new CSS variables in place. */
  theme(css) {
    const style = document.getElementById("hq-vars");
    if (style) style.textContent = css;
  },
};

function mount() {
  const root = document.getElementById("root");
  if (!root) return;
  ReactDOMClient.createRoot(root).render(<I18nContext.Provider value={null}><Page /></I18nContext.Provider>);
}

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", mount);
else mount();

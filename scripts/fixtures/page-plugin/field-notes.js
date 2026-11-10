// [plugin-pages] A fake page plugin for capabilities-gateway.py --page-plugin: written the way upstream dashboard
// plugins are (an IIFE, classic React.createElement, the SDK from window.__HERMES_PLUGIN_SDK__, Tailwind classes and
// dashboard tokens), using most of the SDK so the host's components and bridge show in one page.
(function () {
  "use strict";
  var SDK = window.__HERMES_PLUGIN_SDK__;
  var React = SDK.React;
  var h = React.createElement;
  var useState = SDK.hooks.useState, useEffect = SDK.hooks.useEffect, useCallback = SDK.hooks.useCallback;
  var C = SDK.components;
  var cn = SDK.utils.cn;
  var API = "/api/plugins/field-notes";

  function Stat(props) {
    return h(C.Card, { className: "flex-1 min-w-[140px]" },
      h(C.CardContent, { className: "py-4" },
        h("div", { className: "text-xs uppercase tracking-wide text-muted-foreground" }, props.label),
        h("div", { className: "mt-1 text-2xl font-semibold" }, props.value)));
  }

  function NoteRow(props) {
    var n = props.note;
    return h("div", { className: "flex items-start gap-3 py-3 border-b border-border last:border-b-0" },
      h(C.Checkbox, { checked: !!n.done, onCheckedChange: function (v) { props.onToggle(n, v); } }),
      h("div", { className: "flex-1 min-w-0" },
        h("div", { className: cn("font-medium", n.done && "line-through text-muted-foreground") }, n.title),
        h("div", { className: "text-sm text-muted-foreground" }, n.body)),
      h(C.Badge, { tone: n.tag === "urgent" ? "destructive" : n.tag === "idea" ? "success" : "secondary" }, n.tag),
      h(C.Button, { ghost: true, size: "sm", onClick: function () { props.onDelete(n.id); } }, "Delete"));
  }

  function FieldNotesPage() {
    var _a = useState(null), data = _a[0], setData = _a[1];
    var _b = useState(null), error = _b[0], setError = _b[1];
    var _c = useState(""), title = _c[0], setTitle = _c[1];
    var _d = useState("note"), tag = _d[0], setTag = _d[1];
    var _e = useState(false), adding = _e[0], setAdding = _e[1];
    var toast = SDK.hooks.useToast();
    var load = useCallback(function () {
      SDK.fetchJSON(API + "/notes").then(setData).catch(function (e) { setError(String(e.message || e)); });
    }, []);
    useEffect(load, [load]);
    var del = SDK.hooks.useConfirmDelete({ onDelete: function (id) {
      return SDK.fetchJSON(API + "/notes/" + id, { method: "DELETE" }).then(function () { toast.showToast("Note deleted", "success"); load(); });
    } });
    function add() {
      SDK.fetchJSON(API + "/notes", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ title: title, tag: tag }) })
        .then(function () { setTitle(""); setAdding(false); toast.showToast("Note added", "success"); load(); })
        .catch(function (e) { toast.showToast(String(e.message || e), "error"); });
    }
    function toggle(n, v) {
      SDK.fetchJSON(API + "/notes/" + n.id, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ done: v }) }).then(load);
    }
    if (error) return h(C.Card, null, h(C.CardContent, { className: "py-6 text-destructive" }, error));
    if (!data) return h("div", { className: "p-6 text-muted-foreground" }, "Loading…");
    var notes = data.notes || [];
    return h("div", { className: "flex flex-col gap-4" },
      h("div", { className: "flex items-center justify-between gap-3" },
        h("div", null,
          h("h1", { className: "text-2xl font-semibold" }, "Field Notes"),
          h("p", { className: "text-sm text-muted-foreground" }, "Notes " + (data.bot || "your bot") + " keeps while it works.")),
        h(C.Dialog, { open: adding, onOpenChange: setAdding },
          h(C.DialogTrigger, { asChild: true }, h(C.Button, null, "New Note")),
          h(C.DialogContent, null,
            h(C.DialogHeader, null,
              h(C.DialogTitle, null, "New Note"),
              h(C.DialogDescription, null, "Your bot sees it the next time it reads its notes.")),
            h("div", { className: "flex flex-col gap-3" },
              h(C.Label, { htmlFor: "fn-title" }, "Title"),
              h(C.Input, { id: "fn-title", value: title, placeholder: "What to remember", onChange: function (e) { setTitle(e.target.value); } }),
              h(C.Label, null, "Tag"),
              h(C.Select, { value: tag, onValueChange: setTag },
                h(C.SelectOption, { value: "note" }, "Note"),
                h(C.SelectOption, { value: "idea" }, "Idea"),
                h(C.SelectOption, { value: "urgent" }, "Urgent"))),
            h(C.DialogFooter, null,
              h(C.DialogClose, { asChild: true }, h(C.Button, { outlined: true }, "Cancel")),
              h(C.Button, { onClick: add, disabled: !title.trim() }, "Add"))))),
      h("div", { className: "flex flex-wrap gap-3" },
        h(Stat, { label: "Notes", value: String(notes.length) }),
        h(Stat, { label: "Done", value: String(notes.filter(function (n) { return n.done; }).length) }),
        h(Stat, { label: "Updated", value: SDK.utils.isoTimeAgo(data.updated) })),
      h(C.Tabs, { defaultValue: "all" }, function (active, setActive) {
        var shown = active === "open" ? notes.filter(function (n) { return !n.done; }) : notes;
        return h("div", { className: "flex flex-col gap-3" },
          h(C.TabsList, null,
            h(C.TabsTrigger, { active: active === "all", onClick: function () { setActive("all"); } }, "All"),
            h(C.TabsTrigger, { active: active === "open", onClick: function () { setActive("open"); } }, "Open")),
          h(C.Card, null,
            h(C.CardHeader, null,
              h(C.CardTitle, null, active === "open" ? "Open Notes" : "All Notes"),
              h(C.CardDescription, null, shown.length + " shown")),
            h(C.Separator, null),
            h(C.CardContent, null, shown.length ? shown.map(function (n) {
              return h(NoteRow, { key: n.id, note: n, onToggle: toggle, onDelete: del.requestDelete });
            }) : h("div", { className: "py-6 text-center text-muted-foreground" }, "Nothing here."))));
      }),
      h(C.ConfirmDialog, { open: del.isOpen, title: "Delete this note?", description: "It can’t be brought back.", confirmLabel: "Delete",
        destructive: true, loading: del.isDeleting, onConfirm: del.confirm, onCancel: del.cancel }),
      h(C.Toast, { toast: toast.toast }));
  }

  window.__HERMES_PLUGINS__.register("field-notes", FieldNotesPage);
})();

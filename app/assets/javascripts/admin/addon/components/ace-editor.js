import Component from "@ember/component";
import getURL from "discourse-common/lib/get-url";
import loadScript from "discourse/lib/load-script";
import { observes } from "discourse-common/utils/decorators";
import { on } from "@ember/object/evented";

export default Component.extend({
  mode: "css",
  classNames: ["ace-wrapper"],
  _editor: null,
  _skipContentChangeEvent: null,
  disabled: false,
  htmlPlaceholder: false,

  @observes("editorId")
  editorIdChanged() {
    if (this.autofocus) {
      this.send("focus");
    }
  },

  didRender() {
    this._skipContentChangeEvent = false;
  },

  @observes("content")
  contentChanged() {
    const content = this.content || "";
    if (this._editor && !this._skipContentChangeEvent) {
      this._editor.getSession().setValue(content);
    }
  },

  @observes("mode")
  modeChanged() {
    if (this._editor && !this._skipContentChangeEvent) {
      this._editor.getSession().setMode("ace/mode/" + this.mode);
    }
  },

  @observes("placeholder")
  placeholderChanged() {
    if (this._editor) {
      this._editor.setOptions({
        placeholder: this.placeholder,
      });
    }
  },

  @observes("disabled")
  disabledStateChanged() {
    this.changeDisabledState();
  },

  changeDisabledState() {
    const editor = this._editor;
    if (editor) {
      const disabled = this.disabled;
      editor.setOptions({
        readOnly: disabled,
        highlightActiveLine: !disabled,
        highlightGutterLine: !disabled,
      });
      editor.container.parentNode.setAttribute("data-disabled", disabled);
    }
  },

  _destroyEditor: on("willDestroyElement", function () {
    if (this._editor) {
      this._editor.destroy();
      this._editor = null;
    }
    if (this.appEvents) {
      // xxx: don't run during qunit tests
      this.appEvents.off("ace:resize", this, "resize");
    }

    $(window).off("ace:resize");
  }),

  resize() {
    if (this._editor) {
      this._editor.resize();
    }
  },

  didInsertElement() {
    this._super(...arguments);
    loadScript("/javascripts/ace/ace.js").then(() => {
      window.ace.require(["ace/ace"], (loadedAce) => {
        loadedAce.config.set("loadWorkerFromBlob", false);
        loadedAce.config.set("workerPath", getURL("/javascripts/ace")); // Do not use CDN for workers

        if (this.htmlPlaceholder) {
          this._overridePlaceholder(loadedAce);
        }

        if (!this.element || this.isDestroying || this.isDestroyed) {
          return;
        }
        const editor = loadedAce.edit(this.element.querySelector(".ace"));

        editor.setTheme("ace/theme/chrome");
        editor.setShowPrintMargin(false);
        editor.setOptions({ fontSize: "14px", placeholder: this.placeholder });
        editor.getSession().setMode("ace/mode/" + this.mode);
        editor.on("change", () => {
          this._skipContentChangeEvent = true;
          this.set("content", editor.getSession().getValue());
        });
        if (this.attrs.save) {
          editor.commands.addCommand({
            name: "save",
            exec: () => {
              this.attrs.save();
            },
            bindKey: { mac: "cmd-s", win: "ctrl-s" },
          });
        }
        editor.$blockScrolling = Infinity;
        editor.renderer.setScrollMargin(10, 10);

        this.element.setAttribute("data-editor", editor);
        this._editor = editor;
        this.changeDisabledState();

        $(window)
          .off("ace:resize")
          .on("ace:resize", () => this.appEvents.trigger("ace:resize"));

        if (this.appEvents) {
          // xxx: don't run during qunit tests
          this.appEvents.on("ace:resize", this, "resize");
        }

        if (this.autofocus) {
          this.send("focus");
        }
      });
    });
  },

  actions: {
    focus() {
      if (this._editor) {
        this._editor.focus();
        this._editor.navigateFileEnd();
      }
    },
  },

  _overridePlaceholder(loadedAce) {
    const originalPlaceholderSetter =
      loadedAce.config.$defaultOptions.editor.placeholder.set;

    loadedAce.config.$defaultOptions.editor.placeholder.set = function () {
      if (!this.$updatePlaceholder) {
        const originalRendererOn = this.renderer.on;
        this.renderer.on = function () {};
        originalPlaceholderSetter.call(this, ...arguments);
        this.renderer.on = originalRendererOn;

        const originalUpdatePlaceholder = this.$updatePlaceholder;

        this.$updatePlaceholder = function () {
          originalUpdatePlaceholder.call(this, ...arguments);

          if (this.renderer.placeholderNode) {
            this.renderer.placeholderNode.innerHTML = this.$placeholder || "";
          }
        }.bind(this);

        this.on("input", this.$updatePlaceholder);
      }

      this.$updatePlaceholder();
    };
  },
});

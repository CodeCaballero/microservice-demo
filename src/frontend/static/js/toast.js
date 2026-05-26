/**
 * Copyright 2020 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

(function () {
  var ICONS = {
    success: "\u2713",
    info: "\u2139",
    error: "\u2717"
  };

  function getContainer() {
    var container = document.getElementById("toast-container");
    if (!container) {
      container = document.createElement("div");
      container.id = "toast-container";
      container.className = "toast-container";
      container.setAttribute("aria-live", "polite");
      container.setAttribute("aria-atomic", "true");
      document.body.appendChild(container);
    }
    return container;
  }

  function dismissToast(toast) {
    if (!toast || toast.classList.contains("toast-hiding")) {
      return;
    }
    toast.classList.remove("toast-visible");
    toast.classList.add("toast-hiding");
    setTimeout(function () {
      if (toast.parentNode) {
        toast.parentNode.removeChild(toast);
      }
    }, 300);
  }

  window.showToast = function (options) {
    var opts = typeof options === "string" ? { message: options } : options || {};
    var type = opts.type || "success";
    var title = opts.title || "";
    var message = opts.message || "";
    var duration = opts.duration !== undefined ? opts.duration : 6000;

    var container = getContainer();
    var toast = document.createElement("div");
    toast.className = "toast toast-" + type;
    toast.setAttribute("role", "alert");

    var icon = document.createElement("span");
    icon.className = "toast-icon";
    icon.setAttribute("aria-hidden", "true");
    icon.textContent = ICONS[type] || ICONS.info;

    var body = document.createElement("div");
    body.className = "toast-body";

    if (title) {
      var titleEl = document.createElement("p");
      titleEl.className = "toast-title";
      titleEl.textContent = title;
      body.appendChild(titleEl);
    }

    if (message) {
      var messageEl = document.createElement("p");
      messageEl.className = "toast-message";
      messageEl.textContent = message;
      body.appendChild(messageEl);
    }

    var closeBtn = document.createElement("button");
    closeBtn.type = "button";
    closeBtn.className = "toast-close";
    closeBtn.setAttribute("aria-label", "Dismiss notification");
    closeBtn.textContent = "\u00d7";
    closeBtn.addEventListener("click", function () {
      dismissToast(toast);
    });

    toast.appendChild(icon);
    toast.appendChild(body);
    toast.appendChild(closeBtn);
    container.appendChild(toast);

    requestAnimationFrame(function () {
      toast.classList.add("toast-visible");
    });

    if (duration > 0) {
      setTimeout(function () {
        dismissToast(toast);
      }, duration);
    }

    return toast;
  };

  window.dismissAllToasts = function () {
    var container = document.getElementById("toast-container");
    if (!container) {
      return;
    }
    var toasts = container.querySelectorAll(".toast");
    for (var i = 0; i < toasts.length; i++) {
      dismissToast(toasts[i]);
    }
  };
})();

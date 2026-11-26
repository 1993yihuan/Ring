(function () {
  "use strict";

  var BASELINE_VERSION = "0.2.8";
  var REPO = "1993yihuan/Ring";
  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var finePointer = window.matchMedia("(hover: hover) and (pointer: fine)").matches;

  /* ------------------------------------------------------------
   * 1. Hero Modifier Key Roller (Option <-> Command)
   * ------------------------------------------------------------ */
  (function initKeyRoller() {
    var btn = document.getElementById("key-roller");
    var track = document.getElementById("key-roller-track");
    if (!btn || !track) return;

    var step = 0; // 0 = Option, 1 = Command, 2 = cloned Option
    var paused = false;
    var timer = null;
    var resetting = false;

    function currentKeyName() {
      return step === 1 ? "Command" : "Option";
    }

    function updateAria() {
      var cur = currentKeyName();
      var next = cur === "Option" ? "Command" : "Option";
      btn.setAttribute("aria-label", "触发修饰键：当前显示 " + cur + "，点击切换为 " + next);
    }

    function applyStep(animate) {
      if (!animate || reduceMotion) {
        track.classList.add("no-transition");
        track.style.transform = "translateY(" + (-step * 33.333333).toFixed(4) + "%)";
        void track.offsetHeight;
        track.classList.remove("no-transition");
      } else {
        track.style.transform = "translateY(" + (-step * 33.333333).toFixed(4) + "%)";
      }
      updateAria();
    }

    function snapToZero() {
      if (step !== 2) return;
      step = 0;
      applyStep(false);
      resetting = false;
    }

    track.addEventListener("transitionend", function (e) {
      if (e.propertyName === "transform" && step === 2) {
        snapToZero();
      }
    });

    function advance(animate) {
      if (resetting) snapToZero();
      if (reduceMotion) {
        step = step === 0 ? 1 : 0;
        applyStep(false);
        return;
      }
      step += 1;
      if (step === 2) {
        resetting = true;
        setTimeout(snapToZero, 640);
      }
      applyStep(animate);
    }

    function startTimer() {
      if (reduceMotion || timer !== null) return;
      timer = window.setInterval(function () {
        if (!paused && !document.hidden) {
          advance(true);
        }
      }, 2600);
    }

    btn.addEventListener("click", function () {
      advance(!reduceMotion);
    });

    btn.addEventListener("mouseenter", function () { paused = true; });
    btn.addEventListener("mouseleave", function () { paused = false; });
    btn.addEventListener("focusin", function () { paused = true; });
    btn.addEventListener("focusout", function () { paused = false; });

    updateAria();
    startTimer();
  })();

  /* ------------------------------------------------------------
   * 2. Interactive 3-8 Slot Warm-Paper Ring Demo
   * ------------------------------------------------------------ */
  (function initRingDemo() {
    var ringEl = document.getElementById("ring-demo");
    var slotsList = document.getElementById("ring-slots");
    var labelEl = document.getElementById("ring-label");
    var cyanRotator = document.getElementById("ring-cyan-rotator");
    var hintEl = document.getElementById("demo-hint");
    var countGroup = document.getElementById("slot-count-control");
    var replayBtn = document.getElementById("replay-bloom");
    if (!ringEl || !slotsList || !labelEl || !cyanRotator) return;

    var slots = Array.prototype.slice.call(slotsList.querySelectorAll(".slot"));
    var visibleCount = 8;
    var activeIndex = 2; // Starts on Option A showcase: slot 2 (备忘录 -> 返回 Safari)
    var showcaseActive = true;
    var glowDeg = 90;

    function slotAngle(index, count) {
      return (index * 360) / count;
    }

    function moveGlowTo(targetDeg, isEmpty) {
      var currentMod = ((glowDeg % 360) + 360) % 360;
      var targetMod = ((targetDeg % 360) + 360) % 360;
      var delta = ((targetMod - currentMod + 540) % 360) - 180;
      glowDeg += delta;
      cyanRotator.style.transform = "rotate(" + glowDeg.toFixed(2) + "deg)";
      cyanRotator.classList.toggle("is-dimmed", Boolean(isEmpty));
    }

    function renderActiveState() {
      slots.forEach(function (slot, idx) {
        var isVisible = idx < visibleCount;
        var isCurrent = isVisible && idx === activeIndex;
        var isFg = slot.dataset.foreground === "true";
        slot.classList.toggle("is-active", isCurrent);
        slot.classList.toggle("is-returning", Boolean(isCurrent && isFg));
      });

      if (activeIndex !== null && activeIndex < visibleCount) {
        var activeSlot = slots[activeIndex];
        var isFgSlot = activeSlot.dataset.foreground === "true";
        var isEmpty = activeSlot.dataset.kind === "empty";
        var name = activeSlot.dataset.name || "";
        var prevApp = activeSlot.dataset.prevApp || "";
        labelEl.textContent = isFgSlot ? "返回 " + prevApp : name;
        moveGlowTo(slotAngle(activeIndex, visibleCount), isEmpty);
      } else {
        labelEl.textContent = "Ring";
        cyanRotator.classList.add("is-dimmed");
      }
    }

    function layoutSlots(count) {
      visibleCount = Math.max(3, Math.min(8, count));
      ringEl.setAttribute("data-slots", String(visibleCount));
      slots.forEach(function (slot, idx) {
        var visible = idx < visibleCount;
        slot.classList.toggle("is-hidden", !visible);
        var btn = slot.querySelector(".slot-btn");
        if (btn) btn.tabIndex = visible ? 0 : -1;
        if (visible) {
          slot.style.setProperty("--a", slotAngle(idx, visibleCount).toFixed(2) + "deg");
        }
      });

      if (activeIndex !== null && activeIndex >= visibleCount) {
        activeIndex = 0;
      }
      renderActiveState();
    }

    function setHint(text) {
      if (hintEl) hintEl.textContent = text;
    }

    function selectSlot(index, fromInteraction) {
      if (index < 0 || index >= visibleCount) return;
      if (fromInteraction) showcaseActive = false;
      activeIndex = index;
      renderActiveState();
    }

    slots.forEach(function (slot, idx) {
      var btn = slot.querySelector(".slot-btn");
      if (!btn) return;

      btn.addEventListener("pointerenter", function () {
        selectSlot(idx, true);
        if (slot.dataset.foreground === "true") {
          setHint("已触发「悬停返回」：松手或点击即可切回 " + (slot.dataset.prevApp || "Safari") + "（不隐藏备忘录）");
        } else if (slot.dataset.kind === "empty") {
          setHint("空位：松手不执行动作，可在设置中随时添加应用、网址、文件或锁屏");
        } else {
          setHint("当前模拟前台：备忘录 · 悬停「备忘录」可体验变身返回箭头");
        }
      });

      btn.addEventListener("pointerleave", function () {
        if (showcaseActive) return;
        if (activeIndex === idx) {
          activeIndex = null;
          renderActiveState();
          if (slot.dataset.foreground === "true") {
            setHint("移出已恢复「备忘录」原图标 · 悬停任意槽位继续体验");
          }
        }
      });

      btn.addEventListener("focus", function () {
        selectSlot(idx, true);
      });

      btn.addEventListener("blur", function () {
        if (showcaseActive) return;
        window.requestAnimationFrame(function () {
          if (!slotsList.contains(document.activeElement) && activeIndex === idx) {
            activeIndex = null;
            renderActiveState();
          }
        });
      });

      btn.addEventListener("click", function () {
        selectSlot(idx, true);
        slot.classList.add("is-clicked");
        window.setTimeout(function () {
          slot.classList.remove("is-clicked");
        }, 180);

        if (slot.dataset.foreground === "true") {
          setHint("模拟执行：已切回上一个应用 Safari，备忘录保持开启不隐藏");
        } else if (slot.dataset.kind === "empty") {
          setHint("空位不会触发任何动作，按 Esc 或移回环心同样可取消");
        } else {
          setHint("模拟启动：「" + (slot.dataset.name || "") + "」已就绪（桌面端松手即启动）");
        }
      });
    });

    ringEl.addEventListener("pointerleave", function () {
      if (showcaseActive) return;
      // Moving off the foreground slot restores its original icon!
      activeIndex = null;
      renderActiveState();
      setHint("移出已恢复「备忘录」原图标 · 悬停任意槽位继续体验");
    });

    if (countGroup) {
      var countButtons = Array.prototype.slice.call(countGroup.querySelectorAll(".seg-btn"));
      countButtons.forEach(function (b) {
        b.addEventListener("click", function () {
          var nextCount = parseInt(b.dataset.count || "8", 10);
          countButtons.forEach(function (item) {
            var active = item === b;
            item.classList.toggle("is-active", active);
            item.setAttribute("aria-pressed", active ? "true" : "false");
          });
          layoutSlots(nextCount);
          setHint("已切换为 " + nextCount + " 槽位均匀排布（Ring 支持 3–8 个可见位置）");
        });
      });
    }

    function playBloom() {
      if (reduceMotion) return;
      ringEl.classList.remove("is-blooming");
      void ringEl.offsetWidth;
      ringEl.classList.add("is-blooming");
    }

    if (replayBtn) {
      replayBtn.addEventListener("click", function () {
        if (reduceMotion) {
          setHint("系统已开启「减弱动态效果」，Ring 将立即显示与收起");
          return;
        }
        playBloom();
        setHint("正在演示「轻盈开合」居中缩放淡入动效（展开时长 0–2000ms 可调）");
      });
    }

    // Initial layout & gentle entrance bloom
    layoutSlots(8);
    if (!reduceMotion) {
      ringEl.classList.add("is-blooming");
    }

    // Gentle 3D tilt parallax (desktop fine pointer + motion allowed)
    var stage = document.querySelector(".hero-stage");
    var tilt = document.querySelector(".hero-tilt");
    var heroSection = document.querySelector(".hero-section");
    if (!reduceMotion && finePointer && stage && tilt) {
      var targetX = 0, targetY = 0, curX = 0, curY = 0;
      var maxDeg = 4.2;

      window.addEventListener("mousemove", function (e) {
        var r = stage.getBoundingClientRect();
        if (e.clientY < r.top - 140 || e.clientY > r.bottom + 140) {
          targetX = 0;
          targetY = 0;
          return;
        }
        var dx = (e.clientX - (r.left + r.width / 2)) / (r.width / 2);
        var dy = (e.clientY - (r.top + r.height / 2)) / (r.height / 2);
        dx = Math.max(-1, Math.min(1, dx));
        dy = Math.max(-1, Math.min(1, dy));
        targetX = dx * maxDeg;
        targetY = -dy * maxDeg;
      }, { passive: true });

      if (heroSection) {
        heroSection.addEventListener("mouseleave", function () {
          targetX = 0;
          targetY = 0;
        });
      }

      function tick() {
        curX += (targetX - curX) * 0.12;
        curY += (targetY - curY) * 0.12;
        if (Math.abs(curX) < 0.01 && targetX === 0) curX = 0;
        if (Math.abs(curY) < 0.01 && targetY === 0) curY = 0;
        tilt.style.transform = "rotateY(" + curX.toFixed(3) + "deg) rotateX(" + curY.toFixed(3) + "deg)";
        window.requestAnimationFrame(tick);
      }
      window.requestAnimationFrame(tick);
    }
  })();

  /* ------------------------------------------------------------
   * 3. Silent Latest Release Probe (strictly > baseline 0.2.8)
   * ------------------------------------------------------------ */
  (function probeLatestRelease() {
    if (typeof window.fetch !== "function") return;

    function parseSemver(v) {
      var m = /^v?(\d+)\.(\d+)\.(\d+)$/.exec((v || "").trim());
      if (!m) return null;
      return [parseInt(m[1], 10), parseInt(m[2], 10), parseInt(m[3], 10)];
    }

    function isNewer(remote, base) {
      var a = parseSemver(remote);
      var b = parseSemver(base);
      if (!a || !b) return false;
      for (var i = 0; i < 3; i += 1) {
        if (a[i] > b[i]) return true;
        if (a[i] < b[i]) return false;
      }
      return false;
    }

    var controller = typeof AbortController === "function" ? new AbortController() : null;
    var timeoutId = controller ? window.setTimeout(function () { controller.abort(); }, 2500) : null;

    fetch("https://api.github.com/repos/" + REPO + "/releases/latest", {
      headers: { Accept: "application/vnd.github+json" },
      signal: controller ? controller.signal : undefined
    })
      .then(function (res) {
        if (!res.ok) return null;
        return res.json();
      })
      .then(function (release) {
        if (!release || release.prerelease || release.draft) return;
        var tag = String(release.tag_name || "");
        var cleanVer = tag.replace(/^v/, "");
        if (!isNewer(cleanVer, BASELINE_VERSION)) return;

        var assets = Array.isArray(release.assets) ? release.assets : [];
        var armName = "Ring-" + cleanVer + "-apple-silicon.dmg";
        var intelName = "Ring-" + cleanVer + "-intel.dmg";
        var armAsset = null;
        var intelAsset = null;

        assets.forEach(function (asset) {
          if (!asset || !asset.browser_download_url) return;
          if (asset.name === armName) armAsset = asset.browser_download_url;
          if (asset.name === intelName) intelAsset = asset.browser_download_url;
        });

        if (!armAsset || !intelAsset) return;

        Array.prototype.forEach.call(document.querySelectorAll('[data-download="apple-silicon"]'), function (el) {
          el.setAttribute("href", armAsset);
        });
        Array.prototype.forEach.call(document.querySelectorAll('[data-download="intel"]'), function (el) {
          el.setAttribute("href", intelAsset);
        });
        Array.prototype.forEach.call(document.querySelectorAll("[data-version-meta]"), function (el) {
          el.textContent = "v" + cleanVer + " · macOS 13 及更高 · 开源免费 · 首次打开需在系统设置中允许";
        });
        Array.prototype.forEach.call(document.querySelectorAll("[data-version-compact]"), function (el) {
          el.textContent = "v" + cleanVer + " · macOS 13+ · MIT 开源";
        });
        Array.prototype.forEach.call(document.querySelectorAll("[data-version-short]"), function (el) {
          el.textContent = "v" + cleanVer + " · macOS 13+";
        });
      })
      .catch(function () {
        // Keep static baseline 0.2.8 silently on network/rate-limit failures.
      })
      .finally(function () {
        if (timeoutId !== null) window.clearTimeout(timeoutId);
      });
  })();
})();

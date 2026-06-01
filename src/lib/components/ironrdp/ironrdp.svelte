<!-- 
Copyright (c) Devolutions & contributors
GitHub: Devolutions/IronRDP
Source:  https://github.com/Devolutions/IronRDP/blob/bdde2c76ded7315f7bc91d81a0909a1cb827d870/web-client/iron-remote-desktop/src/iron-remote-desktop.svelte
Changes made:
- Removed custom element
- "capturingInputs" simplified by directly targeting canvas instead of inner
- Added `overflow: hidden !important` to screen-wrapper
-->

<script lang="ts">
  import { onMount } from "svelte";
  import Keyboard from "lucide-svelte/icons/keyboard";

  import { LogType } from "./enums/LogType";
  import { ScreenScale } from "./enums/ScreenScale";

  import type { ResizeEvent } from "./interfaces/ResizeEvent";
  import type { ClipboardTransaction } from "./interfaces/ClipboardTransaction";
  import type { RemoteDesktopModule } from "./interfaces/RemoteDesktopModule";

  import { PublicAPI } from "./services/PublicAPI";
  import { loggingService } from "./services/logging.service";
  import { RemoteDesktopService } from "./services/remote-desktop.service";

  let {
    scale,
    verbose,
    debugwasm,
    flexcenter,
    module,
  }: {
    scale: string;
    verbose: "true" | "false";
    debugwasm: "OFF" | "ERROR" | "WARN" | "INFO" | "DEBUG" | "TRACE";
    flexcenter: string;
    module: RemoteDesktopModule;
  } = $props();

  let isVisible = $state(false);
  let capturingInputs = () => {
    loggingService.info(`
            capturingInputs: ${document.activeElement === canvas}
            current active element: ${document.activeElement}
        `);
    return document.activeElement === canvas;
  };

  let inner: HTMLDivElement;
  let wrapper: HTMLDivElement;
  let screenViewer: HTMLDivElement;
  let canvas: HTMLCanvasElement;
  let mobileKeyboardInput: HTMLTextAreaElement;

  let viewerStyle = $state("");
  let wrapperStyle = $state("");
  let remoteDesktopService = new RemoteDesktopService(module);
  let publicAPI = new PublicAPI(remoteDesktopService);
  let mobileKeyboardActive = $state(false);
  let mobileKeyboardComposing = false;
  type TouchPoint = { clientX: number; clientY: number };
  type TouchGesture =
    | { type: "none" }
    | {
        type: "single";
        start: TouchPoint;
        last: TouchPoint;
        dragging: boolean;
        longPressed: boolean;
      }
    | { type: "scroll"; lastCenter: TouchPoint };
  let touchGesture: TouchGesture = { type: "none" };
  let touchLongPressTimer: ReturnType<typeof setTimeout> | undefined;
  const MOBILE_KEYBOARD_SENTINEL = "\u200b";
  const TOUCH_DRAG_THRESHOLD = 8;
  const TOUCH_LONG_PRESS_TIMEOUT = 750;
  const TOUCH_SCROLL_MULTIPLIER = 1.35;
  const TOUCH_EVENT_OPTIONS = { passive: false };
  const mobileKeyboardHandledCodes = new Set([
    "Escape",
    "Tab",
    "ArrowUp",
    "ArrowDown",
    "ArrowLeft",
    "ArrowRight",
    "Home",
    "End",
    "PageUp",
    "PageDown",
  ]);

  // Firefox's clipboard API is very limited, and doesn't support reading from the clipboard
  // without changing browser settings via `about:config`.
  //
  // For firefox, we will use a different approach by marking `screen-wrapper` component
  // as `contenteditable=true`, and then using the `onpaste`/`oncopy`/`oncut` events.
  let isFirefox = navigator.userAgent.toLowerCase().indexOf("firefox") > -1;

  const CLIPBOARD_MONITORING_INTERVAL = 100; // ms

  let isClipboardApiSupported = false;
  let lastClientClipboardItems = new Map<string, string | Uint8Array>();
  let lastClientClipboardTransaction: ClipboardTransaction | null = null;
  let lastClipboardMonitorLoopError: Error | null = null;

  /* Firefox-specific BEGIN */

  // See `ffRemoteClipboardTransaction` variable docs below
  const FF_REMOTE_CLIPBOARD_TRANSACTION_SET_RETRY_INTERVAL = 100; // ms
  const FF_REMOTE_CLIPBOARD_TRANSACTION_SET_MAX_RETRIES = 30; // 3 seconds (100ms * 30)
  // On Firefox, this interval is used to stop delaying the keyboard events if the paste event has
  // failed and we haven't received any clipboard data from the remote side.
  const FF_LOCAL_CLIPBOARD_COPY_TIMEOUT = 1000; // 1s (For text-only data this should be enough)

  // In Firefox, we need this variable due to fact that `clipboard.writeText()` should only be
  // called in scope of user-initiated event processing (e.g. keyboard event), but we receive
  // clipboard data from the remote side asynchronously in wasm service callback. therefore we
  // set this variable in callback and use its value on the user-initiated copy event.
  let ffRemoteClipboardTransaction: ClipboardTransaction | null = null;
  // For Firefox we need this variable to perform wait loop for the remote side to finish sending
  // clipboard content to the client.
  let ffRemoteClipboardTransactionRetriesLeft = 0;
  let ffPostponeKeyboardEvents = false;
  let ffDelayedKeyboardEvents: KeyboardEvent[] = [];
  let ffCnavasFocused = false;

  /* Firefox-specific END */

  /* Clipboard initialization BEGIN */
  function initClipboard() {
    // Detect if browser supports async Clipboard API
    if (!isFirefox && navigator.clipboard != undefined) {
      if (
        navigator.clipboard.read != undefined &&
        navigator.clipboard.write != undefined
      ) {
        isClipboardApiSupported = true;
      }
    }

    if (isFirefox) {
      remoteDesktopService.setOnRemoteClipboardChanged(
        ffOnRemoteClipboardChanged
      );
      remoteDesktopService.setOnRemoteReceivedFormatList(
        ffOnRemoteReceivedFormatList
      );
      remoteDesktopService.setOnForceClipboardUpdate(onForceClipboardUpdate);
    } else if (isClipboardApiSupported) {
      remoteDesktopService.setOnRemoteClipboardChanged(
        onRemoteClipboardChanged
      );
      remoteDesktopService.setOnForceClipboardUpdate(onForceClipboardUpdate);

      // Start the clipboard monitoring loop
      setTimeout(onMonitorClipboard, CLIPBOARD_MONITORING_INTERVAL);
    }
  }

  /* Clipboard initialization END */

  function isCopyKeyboardEvent(evt: KeyboardEvent) {
    return (
      (evt.ctrlKey && evt.code === "KeyC") ||
      (evt.ctrlKey && evt.code === "KeyX") ||
      evt.code == "Copy" ||
      evt.code == "Cut"
    );
  }

  function isPasteKeyboardEvent(evt: KeyboardEvent) {
    return (evt.ctrlKey && evt.code === "KeyV") || evt.code == "Paste";
  }

  // This function is required to covert `ClipboardTransaction` to a object that can be used
  // with `ClipboardItem` API.
  function clipboardTransactionToRecord(
    transaction: ClipboardTransaction
  ): Record<string, Blob> {
    let result = {} as Record<string, Blob>;

    for (const item of transaction.content()) {
      let mime = item.mime_type();
      let value = new Blob([item.value()], { type: mime });

      result[mime] = value;
    }

    return result;
  }

  // This callback is required to send initial clipboard state if available.
  function onForceClipboardUpdate() {
    try {
      if (lastClientClipboardTransaction) {
        remoteDesktopService.onClipboardChanged(lastClientClipboardTransaction);
      } else {
        remoteDesktopService.onClipboardChangedEmpty();
      }
    } catch (err) {
      console.error("Failed to send initial clipboard state: " + err);
    }
  }

  // This callback is required to update client clipboard state when remote side has changed.
  function onRemoteClipboardChanged(transaction: ClipboardTransaction) {
    try {
      const mime_formats = clipboardTransactionToRecord(transaction);
      const clipboard_item = new ClipboardItem(mime_formats);
      navigator.clipboard.write([clipboard_item]);
    } catch (err) {
      console.error("Failed to set client clipboard: " + err);
    }
  }

  // Called periodically to monitor clipboard changes
  async function onMonitorClipboard() {
    if (!document.hasFocus()) {
      setTimeout(onMonitorClipboard, CLIPBOARD_MONITORING_INTERVAL);
      return;
    }

    try {
      var value = await navigator.clipboard.read();

      // Clipboard is empty
      if (value.length == 0) {
        return;
      }

      // We only support one item at a time
      var item = value[0];

      if (
        !item.types.some(
          (type) => type.startsWith("text/") || type.startsWith("image/png")
        )
      ) {
        // Unsupported types
        return;
      }

      var values = new Map<string, string | Uint8Array>();
      var sameValue = true;

      // Sadly, browsers build new `ClipboardItem` object for each `read` call,
      // so we can't do reference comparison here :(
      //
      // For monitoring loop approach we also can't drop this logic, as it will result in
      // very frequent network activity.
      for (const kind of item.types) {
        // Get blob
        const blobIsString = kind.startsWith("text/");

        const blob = await item.getType(kind);
        const value = blobIsString
          ? await blob.text()
          : new Uint8Array(await blob.arrayBuffer());

        const is_equal = blobIsString
          ? function (
              a: string | Uint8Array | undefined,
              b: string | Uint8Array | undefined
            ) {
              return a === b;
            }
          : function (
              a: string | Uint8Array | undefined,
              b: string | Uint8Array | undefined
            ) {
              if (!(a instanceof Uint8Array) || !(b instanceof Uint8Array)) {
                return false;
              }

              return (
                a != undefined &&
                b != undefined &&
                a.length === b.length &&
                a.every((v, i) => v === b[i])
              );
            };

        const previousValue = lastClientClipboardItems.get(kind);

        if (!is_equal(previousValue, value)) {
          // One of mime types has changed, we need to update the clipboard cache
          sameValue = false;
        }

        values.set(kind, value);
      }

      // Clipboard has changed, we need to acknowledge remote side about it.
      if (!sameValue) {
        lastClientClipboardItems = values;

        let transaction = remoteDesktopService.constructClipboardTransaction();

        // Iterate over `Record` type
        values.forEach((value: string | Uint8Array, key: string) => {
          // skip null/undefined values
          if (value == null || value == undefined) {
            return;
          }

          if (key.startsWith("text/") && typeof value === "string") {
            transaction.add_content(
              remoteDesktopService.constructClipboardContentFromText(key, value)
            );
          } else if (key.startsWith("image/") && value instanceof Uint8Array) {
            transaction.add_content(
              remoteDesktopService.constructClipboardContentFromBinary(
                key,
                value
              )
            );
          }
        });

        if (!transaction.is_empty()) {
          lastClientClipboardTransaction = transaction;
          remoteDesktopService.onClipboardChanged(transaction);
        }
      }
    } catch (err) {
      if (err instanceof Error) {
        const printError =
          lastClipboardMonitorLoopError === null ||
          lastClipboardMonitorLoopError.toString() !== err.toString();
        // Prevent spamming the console with the same error
        if (printError) {
          console.error("Clipboard monitoring error: " + err);
        }
        lastClipboardMonitorLoopError = err;
      }
    } finally {
      setTimeout(onMonitorClipboard, CLIPBOARD_MONITORING_INTERVAL);
    }
  }

  /* Firefox-specific BEGIN */

  function ffOnRemoteReceivedFormatList() {
    try {
      // We are ready to send delayed Ctrl+V events
      ffSimulateDelayedKeyEvents();
    } catch (err) {
      console.error("Failed to send delayed keyboard events: " + err);
    }
  }

  // Only set variable on callback, the real clipboard update will be performed in keyboard
  // callback. (User-initiated event is required for Firefox to allow clipboard write)
  function ffOnRemoteClipboardChanged(transaction: ClipboardTransaction) {
    ffRemoteClipboardTransaction = transaction;
  }

  function ffWaitForRemoteClipboardTransactionSet() {
    if (ffRemoteClipboardTransaction) {
      try {
        let transaction = ffRemoteClipboardTransaction;
        ffRemoteClipboardTransaction = null;
        for (const content of transaction.content()) {
          // Firefox only supports text/plain mime type for clipboard writes :(
          if (content.mime_type() === "text/plain") {
            navigator.clipboard.writeText(content.value());
            break;
          }
        }
      } catch (err) {
        console.error("Failed to set client clipboard: " + err);
      }
    } else if (ffRemoteClipboardTransactionRetriesLeft > 0) {
      ffRemoteClipboardTransactionRetriesLeft--;
      setTimeout(
        ffWaitForRemoteClipboardTransactionSet,
        FF_REMOTE_CLIPBOARD_TRANSACTION_SET_RETRY_INTERVAL
      );
    }
  }

  function ffSimulateDelayedKeyEvents() {
    if (ffDelayedKeyboardEvents.length > 0) {
      for (const evt of ffDelayedKeyboardEvents) {
        // simulate consecutive key events
        keyboardEvent(evt);
      }
      ffDelayedKeyboardEvents = [];
    }
    ffPostponeKeyboardEvents = false;
  }

  function ffOnPasteHandler(evt: ClipboardEvent) {
    // We don't actually want to paste the clipboard data into the `contenteditable` div.
    evt.preventDefault();

    // `onpaste` events are handled only for Firefox, other browsers we use the clipboard API
    // for reading the clipboard.
    if (!isFirefox) {
      // Prevent processing of the paste event by the browser.
      return;
    }

    try {
      let transaction = remoteDesktopService.constructClipboardTransaction();

      if (evt.clipboardData == null) {
        return;
      }

      for (var clipItem of evt.clipboardData.items) {
        let mime = clipItem.type;

        if (mime.startsWith("text/")) {
          clipItem.getAsString((str: string) => {
            let content =
              remoteDesktopService.constructClipboardContentFromText(mime, str);
            transaction.add_content(content);

            if (!transaction.is_empty()) {
              remoteDesktopService.onClipboardChanged(
                transaction as ClipboardTransaction
              );
            }
          });
          break;
        }

        if (mime.startsWith("image/")) {
          let file = clipItem.getAsFile();
          if (file == null) {
            continue;
          }

          file.arrayBuffer().then((buffer: ArrayBuffer) => {
            const strict_buffer = new Uint8Array(buffer);
            let content =
              remoteDesktopService.constructClipboardContentFromBinary(
                mime,
                strict_buffer
              );
            transaction.add_content(content);

            if (!transaction.is_empty()) {
              remoteDesktopService.onClipboardChanged(transaction);
            }
          });
          break;
        }
      }
    } catch (err) {
      console.error("Failed to update remote clipboard: " + err);
    }
  }

  /* Firefox-specific END */

  function initListeners() {
    serverBridgeListeners();
    userInteractionListeners();
    canvas.addEventListener(
      "touchstart",
      handleCanvasTouchStart,
      TOUCH_EVENT_OPTIONS
    );
    canvas.addEventListener(
      "touchmove",
      handleCanvasTouchMove,
      TOUCH_EVENT_OPTIONS
    );
    canvas.addEventListener("touchend", handleCanvasTouchEnd, {
      passive: false,
    });
    canvas.addEventListener("touchcancel", handleCanvasTouchCancel, {
      passive: false,
    });

    function captureKeys(evt: KeyboardEvent) {
      if (capturingInputs()) {
        if (ffPostponeKeyboardEvents) {
          evt.preventDefault();
          ffDelayedKeyboardEvents.push(evt);
          return;
        }

        // For Firefox we need to make `onpaste` event still fire even if
        // keyboard is being captured. Not capturing `Ctrl + V` should not create any
        // side effects, therefore is safe to skip capture for it.
        let isFirefoxPaste = isFirefox && isPasteKeyboardEvent(evt);

        if (isFirefoxPaste) {
          ffPostponeKeyboardEvents = true;
          ffDelayedKeyboardEvents = [];
          ffDelayedKeyboardEvents.push(evt);

          // If during the given timeout we weren't able to finish the copy sequence, we need to
          // simulate all queued keyboard events.
          setTimeout(
            ffSimulateDelayedKeyEvents,
            FF_LOCAL_CLIPBOARD_COPY_TIMEOUT
          );
          return;
        }

        keyboardEvent(evt);
      }
    }

    window.addEventListener("keydown", captureKeys, false);
    window.addEventListener("keyup", captureKeys, false);
  }

  function resetHostStyle() {
    if (flexcenter === "true" && inner) {
      inner.style.flexGrow = "";
      inner.style.display = "";
      inner.style.justifyContent = "";
      inner.style.alignItems = "";
    }
  }

  function setHostStyle(full: boolean) {
    if (flexcenter === "true" && inner) {
      if (!full) {
        inner.style.flexGrow = "1";
        inner.style.display = "flex";
        inner.style.justifyContent = "center";
        inner.style.alignItems = "center";
      } else {
        inner.style.flexGrow = "1";
      }
    }
  }

  function setViewerStyle(
    height: string,
    width: string,
    forceMinAndMax: boolean
  ) {
    let newStyle = `height: ${height}; width: ${width}`;
    if (forceMinAndMax) {
      newStyle = forceMinAndMax
        ? `${newStyle}; max-height: ${height}; max-width: ${width}; min-height: ${height}; min-width: ${width}`
        : `${newStyle}; max-height: initial; max-width: initial; min-height: initial; min-width: initial`;
    }
    viewerStyle = newStyle;
  }

  function setWrapperStyle(height: string, width: string, overflow: string) {
    wrapperStyle = `height: ${height}; width: ${width}; overflow: ${overflow}`;
  }

  function serverBridgeListeners() {
    remoteDesktopService.resize.subscribe((evt: ResizeEvent) => {
      loggingService.info(
        `Resize canvas to: ${evt.desktop_size.width}x${evt.desktop_size.height}`
      );
      canvas.width = evt.desktop_size.width;
      canvas.height = evt.desktop_size.height;
      scaleSession(scale);
    });
  }

  function userInteractionListeners() {
    window.addEventListener("resize", (_evt) => {
      scaleSession(scale);
    });

    remoteDesktopService.scaleObserver.subscribe((s) => {
      loggingService.info("Change scale!");
      scaleSession(s);
    });

    remoteDesktopService.dynamicResize.subscribe((evt) => {
      loggingService.info(
        `Dynamic resize!, width: ${evt.width}, height: ${evt.height}`
      );
      setViewerStyle(evt.width.toString(), evt.height.toString(), true);
    });

    remoteDesktopService.changeVisibilityObservable.subscribe((val) => {
      isVisible = val;
      if (val) {
        //Enforce first scaling and delay the call to scaleSession to ensure Dom is ready.
        setWrapperStyle("100%", "100%", "hidden");
        setTimeout(() => scaleSession(scale), 150);
      }
    });
  }

  function scaleSession(currentSize: ScreenScale | string) {
    resetHostStyle();
    if (isVisible) {
      switch (currentSize) {
        case "fit":
        case ScreenScale.Fit:
          loggingService.info("Size to fit");
          scale = "fit";
          fitResize();
          break;
        case "full":
        case ScreenScale.Full:
          loggingService.info("Size to full");
          fullResize();
          scale = "full";
          break;
        case "real":
        case ScreenScale.Real:
          loggingService.info("Size to real");
          realResize();
          scale = "real";
          break;
      }
    }
  }

  function fullResize() {
    const windowSize = getWindowSize();
    const wrapperBoundingBox = wrapper.getBoundingClientRect();

    const containerWidth = windowSize.x - wrapperBoundingBox.x;
    const containerHeight = windowSize.y - wrapperBoundingBox.y;

    let width = canvas.width;
    let height = canvas.height;

    const ratio = Math.max(
      containerWidth / canvas.width,
      containerHeight / canvas.height
    );
    width = width * ratio;
    height = height * ratio;

    setWrapperStyle(`${containerHeight}px`, `${containerWidth}px`, "auto");

    width = width > 0 ? width : 0;
    height = height > 0 ? height : 0;

    setViewerStyle(`${height}px`, `${width}px`, true);
  }

  function fitResize(realSizeLimit = false) {
    const windowSize = getWindowSize();
    const wrapperBoundingBox = wrapper.getBoundingClientRect();

    const containerWidth = windowSize.x - wrapperBoundingBox.x;
    const containerHeight = windowSize.y - wrapperBoundingBox.y;

    let width = canvas.width;
    let height = canvas.height;

    if (
      !realSizeLimit ||
      containerWidth < canvas.width ||
      containerHeight < canvas.height
    ) {
      const ratio = Math.min(
        containerWidth / canvas.width,
        containerHeight / canvas.height
      );
      width = width * ratio;
      height = height * ratio;
    }

    width = width > 0 ? width : 0;
    height = height > 0 ? height : 0;

    setWrapperStyle("initial", "initial", "hidden");
    setViewerStyle(`${height}px`, `${width}px`, true);
    setHostStyle(false);
  }

  function realResize() {
    const windowSize = getWindowSize();
    const wrapperBoundingBox = wrapper.getBoundingClientRect();

    const containerWidth = windowSize.x - wrapperBoundingBox.x;
    const containerHeight = windowSize.y - wrapperBoundingBox.y;

    if (containerWidth < canvas.width || containerHeight < canvas.height) {
      setWrapperStyle(
        `${Math.min(containerHeight, canvas.height)}px`,
        `${Math.min(containerWidth, canvas.width)}px`,
        "auto"
      );
    } else {
      setWrapperStyle("initial", "initial", "initial");
    }

    setViewerStyle(`${canvas.height}px`, `${canvas.width}px`, true);
    setHostStyle(false);
  }

  function getMousePos(evt: MouseEvent) {
    updateMousePositionFromClientPoint({
      clientX: evt.clientX,
      clientY: evt.clientY,
    });
  }

  function updateMousePositionFromClientPoint(point: TouchPoint) {
    const rect = canvas.getBoundingClientRect(),
      scaleX = canvas.width / rect.width,
      scaleY = canvas.height / rect.height;

    const coord = {
      x: Math.round((point.clientX - rect.left) * scaleX),
      y: Math.round((point.clientY - rect.top) * scaleY),
    };

    remoteDesktopService.updateMousePosition(coord);
  }

  function setMouseButtonState(state: MouseEvent, isDown: boolean) {
    if (isFirefox) {
      if (isDown && state.button == 0 && !ffCnavasFocused) {
        // Do not capture first mouse down event on Firefox, as we need to transfer focus to the
        // canvas first in order to receive paste events.
        // wasmService.mouseButtonState(state, isDown, false);
        // Focus `contenteditable` element to receive `on_paste` events
        screenViewer.focus();
        // Finish the focus sequence on Firefox
        ffCnavasFocused = true;
      } else {
        // This is needed to prevent visible "double click" selection on
        // `texteditable` element
        screenViewer.blur();
      }
    }

    remoteDesktopService.mouseButtonState(state, isDown, true);
  }

  function mouseWheel(evt: WheelEvent) {
    evt.preventDefault();
    remoteDesktopService.mouseWheel(evt);
  }

  function pointFromTouch(touch: Touch): TouchPoint {
    return {
      clientX: touch.clientX,
      clientY: touch.clientY,
    };
  }

  function centerFromTouches(touches: TouchList): TouchPoint {
    return {
      clientX: (touches[0].clientX + touches[1].clientX) / 2,
      clientY: (touches[0].clientY + touches[1].clientY) / 2,
    };
  }

  function pointDistance(a: TouchPoint, b: TouchPoint) {
    return Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
  }

  function captureCanvasTouch(evt: TouchEvent) {
    evt.preventDefault();
    evt.stopPropagation();
  }

  function clearTouchLongPressTimer() {
    if (touchLongPressTimer === undefined) return;
    clearTimeout(touchLongPressTimer);
    touchLongPressTimer = undefined;
  }

  function startTouchLongPressTimer() {
    clearTouchLongPressTimer();
    touchLongPressTimer = setTimeout(() => {
      touchLongPressTimer = undefined;

      if (
        touchGesture.type !== "single" ||
        touchGesture.dragging ||
        touchGesture.longPressed
      ) {
        return;
      }

      updateMousePositionFromClientPoint(touchGesture.last);
      remoteDesktopService.sendMouseButton(2, true);
      remoteDesktopService.sendMouseButton(2, false);
      touchGesture = {
        ...touchGesture,
        longPressed: true,
      };
    }, TOUCH_LONG_PRESS_TIMEOUT);
  }

  function beginTouchScroll(touches: TouchList) {
    clearTouchLongPressTimer();

    if (touchGesture.type === "single" && touchGesture.dragging) {
      remoteDesktopService.sendMouseButton(0, false);
    }

    const center = centerFromTouches(touches);
    updateMousePositionFromClientPoint(center);
    touchGesture = { type: "scroll", lastCenter: center };
  }

  function handleCanvasTouchStart(evt: TouchEvent) {
    if (!isVisible) return;
    captureCanvasTouch(evt);
    canvas.focus({ preventScroll: true });

    if (evt.touches.length >= 2) {
      beginTouchScroll(evt.touches);
      return;
    }

    const point = pointFromTouch(evt.touches[0]);
    updateMousePositionFromClientPoint(point);
    touchGesture = {
      type: "single",
      start: point,
      last: point,
      dragging: false,
      longPressed: false,
    };
    startTouchLongPressTimer();
  }

  function handleCanvasTouchMove(evt: TouchEvent) {
    if (!isVisible) return;
    captureCanvasTouch(evt);

    if (evt.touches.length >= 2) {
      if (touchGesture.type !== "scroll") {
        beginTouchScroll(evt.touches);
        return;
      }

      const center = centerFromTouches(evt.touches);
      const deltaX =
        (touchGesture.lastCenter.clientX - center.clientX) *
        TOUCH_SCROLL_MULTIPLIER;
      const deltaY =
        (touchGesture.lastCenter.clientY - center.clientY) *
        TOUCH_SCROLL_MULTIPLIER;

      updateMousePositionFromClientPoint(center);

      if (Math.abs(deltaY) >= Math.abs(deltaX)) {
        remoteDesktopService.sendWheelRotation(true, deltaY);
      } else {
        remoteDesktopService.sendWheelRotation(false, deltaX);
      }

      touchGesture = { type: "scroll", lastCenter: center };
      return;
    }

    if (touchGesture.type !== "single" || evt.touches.length !== 1) return;

    const point = pointFromTouch(evt.touches[0]);
    updateMousePositionFromClientPoint(point);
    let dragging = touchGesture.dragging;
    const longPressed = touchGesture.longPressed;

    if (
      !longPressed &&
      !dragging &&
      pointDistance(touchGesture.start, point) >= TOUCH_DRAG_THRESHOLD
    ) {
      clearTouchLongPressTimer();
      remoteDesktopService.sendMouseButton(0, true);
      dragging = true;
    }

    touchGesture = {
      type: "single",
      start: touchGesture.start,
      last: point,
      dragging,
      longPressed,
    };
  }

  function finishSingleTouch(sendTap: boolean) {
    if (touchGesture.type !== "single") return;
    clearTouchLongPressTimer();

    updateMousePositionFromClientPoint(touchGesture.last);

    if (touchGesture.dragging) {
      remoteDesktopService.sendMouseButton(0, false);
    } else if (sendTap && !touchGesture.longPressed) {
      remoteDesktopService.sendMouseButton(0, true);
      remoteDesktopService.sendMouseButton(0, false);
    }

    touchGesture = { type: "none" };
  }

  function handleCanvasTouchEnd(evt: TouchEvent) {
    if (!isVisible) return;
    captureCanvasTouch(evt);

    if (touchGesture.type === "scroll") {
      if (evt.touches.length >= 2) {
        const center = centerFromTouches(evt.touches);
        touchGesture = { type: "scroll", lastCenter: center };
      } else {
        touchGesture = { type: "none" };
      }
      return;
    }

    finishSingleTouch(evt.touches.length === 0);
  }

  function handleCanvasTouchCancel(evt: TouchEvent) {
    captureCanvasTouch(evt);
    clearTouchLongPressTimer();

    if (touchGesture.type === "single" && touchGesture.dragging) {
      remoteDesktopService.sendMouseButton(0, false);
    }

    touchGesture = { type: "none" };
  }

  function setMouseIn(evt: MouseEvent) {
    canvas.focus();
    remoteDesktopService.mouseIn(evt);
  }

  function setMouseOut(evt: MouseEvent) {
    remoteDesktopService.mouseOut(evt);
  }

  function keyboardEvent(evt: KeyboardEvent) {
    const browserHasClipboardAccess =
      navigator.clipboard != undefined &&
      navigator.clipboard.writeText != undefined;

    if (isFirefox && browserHasClipboardAccess && isCopyKeyboardEvent(evt)) {
      // Special processing for firefox, as the only way Firefox supports clipboard write is
      // only after some user-initiated event (e.g. keyboard event).
      // therefore we need to wait here for the clipboard data to be ready.

      ffRemoteClipboardTransactionRetriesLeft =
        FF_REMOTE_CLIPBOARD_TRANSACTION_SET_MAX_RETRIES;
      ffWaitForRemoteClipboardTransactionSet();
    }

    remoteDesktopService.sendKeyboardEvent(evt);

    // Propagate further
    return true;
  }

  function toggleMobileKeyboard() {
    if (
      mobileKeyboardActive ||
      document.activeElement === mobileKeyboardInput
    ) {
      mobileKeyboardInput.blur();
      canvas.focus({ preventScroll: true });
      return;
    }

    resetMobileKeyboardInput();
    mobileKeyboardInput.focus({ preventScroll: true });
  }

  function mobileKeyboardTogglePointerDown(evt: PointerEvent) {
    evt.preventDefault();
    toggleMobileKeyboard();
  }

  function resetMobileKeyboardInput() {
    if (!mobileKeyboardInput) return;

    mobileKeyboardInput.value = MOBILE_KEYBOARD_SENTINEL;

    requestAnimationFrame(() => {
      try {
        const position = mobileKeyboardInput.value.length;
        mobileKeyboardInput.setSelectionRange(position, position);
      } catch {
        // Some mobile browsers reject selection changes while the keyboard opens.
      }
    });
  }

  function stripMobileKeyboardSentinel(value: string) {
    return value.split(MOBILE_KEYBOARD_SENTINEL).join("");
  }

  function sendMobileKeyboardText(value: string) {
    const text = stripMobileKeyboardSentinel(value);
    if (!text) return;

    let textBuffer = "";
    const flushTextBuffer = () => {
      if (!textBuffer) return;
      remoteDesktopService.sendUnicodeText(textBuffer);
      textBuffer = "";
    };

    const chars = Array.from(text);
    for (let i = 0; i < chars.length; i++) {
      const char = chars[i];

      if (char === "\r" || char === "\n") {
        if (char === "\r" && chars[i + 1] === "\n") {
          i++;
        }

        flushTextBuffer();
        remoteDesktopService.sendKeyCode("Enter");
        continue;
      }

      textBuffer += char;
    }

    flushTextBuffer();
  }

  function mobileKeyboardBeforeInput(evt: InputEvent) {
    if (!isVisible) return;

    switch (evt.inputType) {
      case "deleteContentBackward":
      case "deleteWordBackward":
      case "deleteSoftLineBackward":
      case "deleteHardLineBackward":
        evt.preventDefault();
        remoteDesktopService.sendKeyCode("Backspace");
        resetMobileKeyboardInput();
        break;
      case "deleteContentForward":
      case "deleteWordForward":
      case "deleteSoftLineForward":
      case "deleteHardLineForward":
        evt.preventDefault();
        remoteDesktopService.sendKeyCode("Delete");
        resetMobileKeyboardInput();
        break;
      case "insertLineBreak":
      case "insertParagraph":
        evt.preventDefault();
        remoteDesktopService.sendKeyCode("Enter");
        resetMobileKeyboardInput();
        break;
      case "insertText":
        if (evt.data === "\r" || evt.data === "\n") {
          evt.preventDefault();
          remoteDesktopService.sendKeyCode("Enter");
          resetMobileKeyboardInput();
        }
        break;
    }
  }

  function mobileKeyboardInputEvent() {
    if (!isVisible || mobileKeyboardComposing) return;
    const value = mobileKeyboardInput.value;

    if (value === "") {
      remoteDesktopService.sendKeyCode("Backspace");
      resetMobileKeyboardInput();
      return;
    }

    if (value !== MOBILE_KEYBOARD_SENTINEL) {
      sendMobileKeyboardText(value);
    }

    resetMobileKeyboardInput();
  }

  function mobileKeyboardCompositionStart() {
    mobileKeyboardComposing = true;
  }

  function mobileKeyboardCompositionEnd(evt: CompositionEvent) {
    mobileKeyboardComposing = false;
    const value =
      stripMobileKeyboardSentinel(mobileKeyboardInput.value) || evt.data;
    if (value) {
      sendMobileKeyboardText(value);
    }
    resetMobileKeyboardInput();
  }

  function mobileKeyboardKeyDown(evt: KeyboardEvent) {
    if (!mobileKeyboardHandledCodes.has(evt.code)) return;
    evt.preventDefault();
    remoteDesktopService.sendKeyCode(evt.code);
    resetMobileKeyboardInput();
  }

  function getWindowSize() {
    const win = window;
    const doc = document;
    const docElem = doc.documentElement;
    const body = doc.getElementsByTagName("body")[0];
    const x = win.innerWidth ?? docElem.clientWidth ?? body.clientWidth;
    const y = win.innerHeight ?? docElem.clientHeight ?? body.clientHeight;
    return { x, y };
  }

  async function initcanvas() {
    loggingService.info("Start canvas initialization.");

    // Set a default canvas size. Need more test to know if i can remove it.
    canvas.width = 800;
    canvas.height = 600;

    const logLevel = LogType[debugwasm] ?? LogType.INFO;
    await remoteDesktopService.init(logLevel);
    remoteDesktopService.setCanvas(canvas);

    initListeners();

    let result = { irgUserInteraction: publicAPI.getExposedFunctions() };

    loggingService.info("Component ready");
    loggingService.info("Dispatching ready event");
    // bubbles:true is significant here, all our consumer code expect this specific event
    // but they only listen to the event on the custom element itself, not on the inner div
    // in Svelte 3, we had direct access to the customelement, but now in Svelte5, we have to
    // dispatch the event on the inner div, and bubble it up to the custom element.
    inner.dispatchEvent(
      new CustomEvent("ready", {
        detail: result,
        bubbles: true,
        composed: true,
      })
    );
  }

  onMount(async () => {
    loggingService.verbose = verbose === "true";
    loggingService.info("Dom ready");
    await initcanvas();
    initClipboard();
    mobileKeyboardInput.setAttribute("autocorrect", "off");
    resetMobileKeyboardInput();
    canvas.focus();
  });
</script>

<div bind:this={inner}>
  <div
    bind:this={wrapper}
    class="screen-wrapper scale-{scale}"
    class:hidden={!isVisible}
    class:capturing-inputs={capturingInputs}
    style={wrapperStyle}
  >
    <div
      bind:this={screenViewer}
      class="screen-viewer"
      style={viewerStyle}
      contenteditable={isFirefox}
      onpaste={ffOnPasteHandler}
      onselectstart={(event) => {
        event.preventDefault();
      }}
    >
      <canvas
        bind:this={canvas}
        onmousemove={getMousePos}
        onmousedown={(event) => setMouseButtonState(event, true)}
        onmouseup={(event) => setMouseButtonState(event, false)}
        onmouseleave={(event) => {
          setMouseButtonState(event, false);
          setMouseOut(event);
        }}
        onmouseenter={(event) => {
          setMouseIn(event);
        }}
        oncontextmenu={(event) => event.preventDefault()}
        onwheel={mouseWheel}
        onselectstart={(event) => {
          event.preventDefault();
        }}
        draggable="false"
        id="renderer"
        tabindex="0"
      ></canvas>
      <button
        class="mobile-keyboard-toggle"
        class:active={mobileKeyboardActive}
        aria-label="Toggle keyboard"
        title="Toggle keyboard"
        type="button"
        onpointerdown={mobileKeyboardTogglePointerDown}
      >
        <Keyboard aria-hidden="true" />
      </button>
      <textarea
        bind:this={mobileKeyboardInput}
        class="mobile-keyboard-input"
        autocomplete="off"
        autocapitalize="none"
        inputmode="text"
        spellcheck="false"
        tabindex="-1"
        rows="1"
        onbeforeinput={mobileKeyboardBeforeInput}
        oninput={mobileKeyboardInputEvent}
        oncompositionstart={mobileKeyboardCompositionStart}
        oncompositionend={mobileKeyboardCompositionEnd}
        onkeydown={mobileKeyboardKeyDown}
        onfocus={() => {
          mobileKeyboardActive = true;
        }}
        onblur={() => {
          mobileKeyboardActive = false;
        }}
      ></textarea>
    </div>
  </div>
</div>

<style>
  .screen-wrapper {
    position: relative;
    overflow: hidden !important;
    overscroll-behavior: none;
  }

  .capturing-inputs {
    outline: 1px solid rgba(0, 97, 166, 0.7);
    outline-offset: -1px;
  }

  .screen-viewer {
    user-select: none;
    -webkit-user-select: none;
    -webkit-touch-callout: none;
  }

  canvas {
    width: 100%;
    height: 100%;
    touch-action: none;
    user-select: none;
    -webkit-user-select: none;
    -webkit-touch-callout: none;
    -webkit-user-drag: none;
    -webkit-tap-highlight-color: transparent;
  }

  .mobile-keyboard-toggle {
    display: none;
  }

  .mobile-keyboard-input {
    display: none;
    position: fixed;
    left: 0;
    bottom: 0;
    width: 1px;
    height: 1px;
    opacity: 0.01;
    border: 0;
    outline: 0;
    padding: 0;
    resize: none;
    color: transparent;
    background: transparent;
    caret-color: transparent;
    user-select: text;
    -webkit-user-select: text;
  }

  @media (hover: none) and (pointer: coarse) {
    .mobile-keyboard-toggle {
      position: absolute;
      right: max(12px, env(safe-area-inset-right));
      bottom: max(12px, env(safe-area-inset-bottom));
      z-index: 20;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 44px;
      height: 44px;
      border: 1px solid rgba(148, 163, 184, 0.55);
      border-radius: 8px;
      color: rgb(15, 23, 42);
      background: rgba(255, 255, 255, 0.86);
      box-shadow: 0 8px 22px rgba(15, 23, 42, 0.18);
      backdrop-filter: blur(8px);
      -webkit-backdrop-filter: blur(8px);
    }

    .mobile-keyboard-toggle.active {
      color: rgb(255, 255, 255);
      background: rgba(15, 23, 42, 0.88);
      border-color: rgba(15, 23, 42, 0.88);
    }

    .mobile-keyboard-toggle :global(svg) {
      width: 22px;
      height: 22px;
    }

    .mobile-keyboard-input {
      display: block;
    }
  }

  ::selection {
    background-color: transparent;
  }

  .screen-wrapper.hidden {
    pointer-events: none !important;
    position: absolute !important;
    visibility: hidden;
    height: 100%;
    width: 100%;
    transform: translate(-100%, -100%);
  }
</style>

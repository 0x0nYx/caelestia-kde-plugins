import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import QtQuick.Controls
import QtQuick.Shapes
import qs.utils
import qs.services.api
import qs.components
import qs.components.controls
import qs.components.images
import Caelestia
import Caelestia.Config as ShellConfig
import Caelestia.Models
import qs.services
import ".."
import ".." as PluginStyle
import "components" as Components
import "views" as Views

PanelWindow {
  id: appWallpaper
  
  property var colors
  property bool showing: false
  property bool isMainScreen: true
  
  property bool hideMouse: false
  property bool canUnhideMouse: false
  property int defaultHideMouseDuration: 600

  Timer {
      id: hideMouseTimer
      interval: appWallpaper.defaultHideMouseDuration
      onTriggered: {
          appWallpaper.canUnhideMouse = true
          interval = appWallpaper.defaultHideMouseDuration
      }
  }

  function hideCursor(delay) {
      hideMouseTimer.stop()
      hideMouseTimer.interval = (delay !== undefined && delay > 0) ? delay : appWallpaper.defaultHideMouseDuration
      appWallpaper.canUnhideMouse = false
      appWallpaper.hideMouse = true
      hideCursorArea.lastX = -1
      hideCursorArea.lastY = -1
      hideMouseTimer.restart()
  }

  function centerCursor() {
      var cx = 0
      var cy = 0
      if (appWallpaper.screen) {
          cx = Math.round(appWallpaper.screen.x + appWallpaper.screen.width / 2)
          cy = Math.round(appWallpaper.screen.y + appWallpaper.screen.height / 2)
      } else {
          cx = Math.round(appWallpaper.width / 2)
          cy = Math.round(appWallpaper.height / 2)
      }
      if (typeof CUtils !== "undefined" && typeof CUtils.setCursorPos === "function") {
          CUtils.setCursorPos(cx, cy)
      }
  }

  property string currentWallpaperTab: "All"

  Timer {
    id: previewTimer
    interval: 500
    onTriggered: {
      if (!appWallpaper.showing || !appWallpaper.cardVisible) return
      var idx = appWallpaper.currentSelectedIndex()
      if (idx >= 0 && appWallpaper.wallpaperResults.values && idx < appWallpaper.wallpaperResults.values.length) {
        var wall = appWallpaper.wallpaperResults.values[idx]
        if (wall && wall.path) CaelestiaApi.visuals.wallpaper.preview(wall.path)
      }
    }
  }

  function currentSelectedIndex() {
    if (appWallpaper.isSliceMode) return sliceListView.currentIndex
    if (appWallpaper.isHexMode) {
      var r = Math.max(1, Config.hexRows || 3)
      return hexListView._selectedCol * r + hexListView._selectedRow
    }
    if (appWallpaper.isGridMode) return thumbGridView.currentIndex
    return -1
  }

  function selectIndex(targetIdx) {
    if (targetIdx < 0) return
    if (appWallpaper.isSliceMode) {
      sliceListView.currentIndex = targetIdx
    } else if (appWallpaper.isHexMode) {
      var r = Math.max(1, Config.hexRows || 3)
      var col = Math.floor(targetIdx / r)
      var row = targetIdx % r
      hexListView.currentIndex = col
      hexListView._selectedCol = col
      hexListView._selectedRow = row
    } else if (appWallpaper.isGridMode) {
      thumbGridView.currentIndex = targetIdx
      thumbGridView._ensureVisible(targetIdx)
    }
  }

  function normalizePath(p) {
    if (!p) return ""
    var s = String(p).replace(/^file:\/\//, "").trim()
    try { s = decodeURIComponent(s) } catch(e) {}
    return s
  }

  function findActualCurrentIndex() {
    var actual = normalizePath(CaelestiaApi.visuals.wallpaper ? (CaelestiaApi.visuals.wallpaper.actualCurrent || CaelestiaApi.visuals.wallpaper.current) : "")
    if (!actual) return -1
    var arr = appWallpaper.wallpaperResults ? appWallpaper.wallpaperResults.values : []
    if (!arr || arr.length === 0) return -1
    for (var i = 0; i < arr.length; i++) {
      var w = arr[i]
      if (w && w.path) {
        var wp = normalizePath(w.path)
        if (wp === actual) return i
      }
    }
    return -1
  }

  function scrollToCurrent() {
    var targetIdx = findActualCurrentIndex()
    if (targetIdx >= 0) {
      appWallpaper.selectIndex(targetIdx)
    }
  }

  property var wallpaperResults: ScriptModel {
    id: scriptModel

    readonly property string search: {
      const raw = (topSearchBar.text || "").trim()
      if (raw.toLowerCase().startsWith("wall ")) {
        return raw.split(" ").slice(1).join(" ").trim()
      }
      if (raw.toLowerCase() === "wall") {
        return ""
      }
      return raw
    }

    values: {
      var _dummy = CaelestiaApi.visuals.wallpaper.list;
      let res = [];
      const targetCategory = (appWallpaper.currentWallpaperTab && appWallpaper.currentWallpaperTab !== "All") ? appWallpaper.currentWallpaperTab : null;
      const baseDir = Paths.wallsdir;

      if (search) {
        const allWalls = Array.from(CaelestiaApi.visuals.wallpaper.query(search) || []);
        if (targetCategory === "Main") {
          res = allWalls.filter(w => w.parentDir === baseDir);
        } else if (targetCategory) {
          res = allWalls.filter(w => {
            let cat = (w.parentDir || "").slice(baseDir.length + 1);
            if (cat.includes("/")) cat = cat.slice(0, cat.indexOf("/"));
            return cat === targetCategory;
          });
        } else {
          res = allWalls;
        }
      } else {
        if (targetCategory && CaelestiaApi.visuals.wallpaper.grouped) {
          res = Array.from(CaelestiaApi.visuals.wallpaper.grouped[targetCategory] || []);
        } else {
          const rawList = CaelestiaApi.visuals.wallpaper.list;
          res = rawList ? Array.from(rawList) : [];
        }
      }
      return res;
    }

    onValuesChanged: {
      let idx = search ? 0 : appWallpaper.findActualCurrentIndex();
      let targetIdx = Math.max(0, idx);
      if (values && values.length > 0 && targetIdx >= 0 && targetIdx < values.length) {
        appWallpaper.selectIndex(targetIdx);
        if (appWallpaper.showing && appWallpaper.cardVisible && search) {
          previewTimer.restart();
        }
      }
    }
  }

  Component.onDestruction: {
    if (typeof CaelestiaApi.visuals.wallpaper.stopPreview === "function") {
      CaelestiaApi.visuals.wallpaper.stopPreview()
    }
  }

  onShowingChanged: {
    if (showing) {
      if (topSearchBar.text !== "") {
          topSearchBar.text = ""
      }
      appWallpaper.hideCursor(appWallpaper.defaultHideMouseDuration)
      appWallpaper.scrollToCurrent()
      cardShowTimer.restart()
    } else {
      appWallpaper.hideMouse = false
      appWallpaper.canUnhideMouse = false
      hideMouseTimer.stop()
      previewTimer.stop()
      scrollTimer.stop()
      settleTimer.stop()
      cardVisible = false
      if (typeof CaelestiaApi.visuals.wallpaper.stopPreview === "function") {
          CaelestiaApi.visuals.wallpaper.stopPreview()
      }
      if (topSearchBar.text !== "") {
          topSearchBar.text = ""
      }
    }
  }

  function closeRequested() {
      if (typeof settingsPanel !== "undefined" && settingsPanel.showing) {
          settingsPanel.showing = false;
      } else {
          appWallpaper.showing = false;
      }
  }

  Connections {
      target: typeof settingsPanel !== "undefined" ? settingsPanel : null
      function onShowingChanged() {
          if (settingsPanel.showing) root.settingsOpenCount++
          else root.settingsOpenCount--
      }
  }

  Connections {
      target: root
      function onCloseSettingsRequested() {
          if (typeof settingsPanel !== "undefined") {
              settingsPanel.showing = false
          }
      }
  }

  Timer {
    id: cardShowTimer
    interval: 50
    onTriggered: {
        appWallpaper.cardVisible = true
        appWallpaper.scrollToCurrent()
        scrollTimer.restart()
    }
  }

  Timer {
      id: scrollTimer
      interval: 100
      onTriggered: {
          appWallpaper.scrollToCurrent()
          settleTimer.restart()
      }
  }

  Timer {
      id: settleTimer
      interval: 150
      onTriggered: {
          appWallpaper.scrollToCurrent()
      }
  }



  Timer {
    id: focusTimer
    interval: 50
    onTriggered: {
      if (appWallpaper.isSliceMode) sliceListView.forceActiveFocus()
      else if (appWallpaper.isHexMode) hexListView.forceActiveFocus()
      else if (appWallpaper.isGridMode) thumbGridView.forceActiveFocus()
    }
  }

  property int sliceWidth: Config.sliceWidth
  
  Shortcut {
    sequences: ["Tab", "Right", "Down"]
    onActivated: appWallpaper.cycleNext()
    enabled: appWallpaper.cardVisible && appWallpaper.isMainScreen && !topSearchBar.activeFocus
  }

  Shortcut {
    sequences: ["Shift+Tab", "Left", "Up"]
    onActivated: appWallpaper.cyclePrev()
    enabled: appWallpaper.cardVisible && appWallpaper.isMainScreen && !topSearchBar.activeFocus
  }

  property int expandedWidth: Config.expandedWidth
  property int sliceHeight: Config.sliceHeight
  property int skewOffset: Config.skewOffset
  property int sliceSpacing: Config.sliceSpacing
  property int visibleCount: Config.visibleCount

  property bool isSliceMode:  Config.displayMode === "slice"
  property bool isHexMode:    Config.displayMode === "hex"
  property bool isGridMode:   Config.displayMode === "wall"

  property string _lastMode: Config.displayMode
  Connections {
    target: Config
    function onDisplayModeChanged() {
      if (Config.displayMode !== appWallpaper._lastMode) {
        appWallpaper._lastMode = Config.displayMode
        Qt.callLater(function() { gc() })
      }
    }
  }

  readonly property int _hexCellW: Config.hexRadius * 2
  readonly property int _hexCellH: Math.ceil(Config.hexRadius * 1.73205)
  readonly property int hexGridWidth: _hexCellW * Config.hexCols + Config.hexRadius
  readonly property int hexGridHeight: _hexCellH * Config.hexRows + (Config.hexRows > 1 ? _hexCellH * 0.5 : 0)

  readonly property int _gridCellGap: 8
  readonly property int _gridTotalW: Config.gridColumns * (Config.gridThumbWidth + _gridCellGap)
  readonly property int _gridTotalH: Config.gridRows * (Config.gridThumbHeight + _gridCellGap)

  property int topBarHeight: 90
  property int bottomBarHeight: 90
  property int cardWidth: {
    if (isHexMode)    return hexGridWidth + 60
    if (isGridMode)   return _gridTotalW + 40
    return 1600
  }
  property int cardHeight: {
    if (isHexMode)    return hexGridHeight + topBarHeight + bottomBarHeight
    if (isGridMode)   return _gridTotalH + topBarHeight + bottomBarHeight
    return sliceHeight + topBarHeight + bottomBarHeight
  }

  property bool cardVisible: false

  property int lastContentX: 0
  property int lastIndex: 0

  function resetScroll() {
    lastContentX = 0
    lastIndex = 0
    sliceListView.currentIndex = 0
    if (appWallpaper.wallpaperResults.values && appWallpaper.wallpaperResults.values.length > 0)
      sliceListView.positionViewAtIndex(0, ListView.Beginning)
  }

  Timer {
    id: interactionBlockerTimer
    interval: 300
  }
  property bool blockHover: interactionBlockerTimer.running

  function cycleNext(step, shouldHideCursor) {
      if (shouldHideCursor !== false) appWallpaper.hideCursor(100)
      if (!appWallpaper.wallpaperResults.values || appWallpaper.wallpaperResults.values.length === 0) return
      interactionBlockerTimer.restart()
      var s = step || 1
      var count = appWallpaper.wallpaperResults.values.length
      var cur = appWallpaper.currentSelectedIndex()
      var nextIdx = (cur + s) % count
      if (nextIdx < 0) nextIdx += count
      appWallpaper.selectIndex(nextIdx)
  }

  function cyclePrev(step, shouldHideCursor) {
      if (shouldHideCursor !== false) appWallpaper.hideCursor(100)
      if (!appWallpaper.wallpaperResults.values || appWallpaper.wallpaperResults.values.length === 0) return
      interactionBlockerTimer.restart()
      var s = step || 1
      var count = appWallpaper.wallpaperResults.values.length
      var cur = appWallpaper.currentSelectedIndex()
      var nextIdx = (cur - s) % count
      if (nextIdx < 0) nextIdx += count
      appWallpaper.selectIndex(nextIdx)
  }

  property bool realShowing: appWallpaper.showing
  property real tintOpacity: realShowing ? 1.0 : 0.0
  Behavior on tintOpacity { NumberAnimation { duration: 300 } }

  visible: appWallpaper.showing || tintOpacity > 0
  color: "transparent"

  anchors { top: true; bottom: true; left: true; right: true }

  WlrLayershell.namespace: "wallpaper-selector"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: appWallpaper.showing ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  exclusionMode: ExclusionMode.Ignore

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.5)
    opacity: appWallpaper.tintOpacity
  }

  MouseArea {
    anchors.fill: parent
    onClicked: appWallpaper.closeRequested()
  }

  Item {
      id: cardContainer

      width: appWallpaper.cardWidth
      height: appWallpaper.cardHeight
      anchors.centerIn: parent
      visible: appWallpaper.showing && appWallpaper.cardVisible && appWallpaper.isMainScreen

      property bool animateIn: appWallpaper.cardVisible

      onVisibleChanged: {
      }

      onAnimateInChanged: {
        fadeInAnim.stop()
        if (animateIn) {
          opacity = 0
          fadeInAnim.start()
          focusTimer.restart()
        }
      }

      NumberAnimation {
        id: fadeInAnim
        target: cardContainer
        property: "opacity"
        from: 0; to: 1
        duration: 400
        easing.type: Easing.OutCubic
      }

      MouseArea {
        anchors.fill: parent
        onClicked: {}
      }

      Item {
        id: backgroundRect
        anchors.fill: parent

        Components.TopSearchBar {
            id: topSearchBar
            anchors.top: parent.top
            anchors.topMargin: 25
            anchors.horizontalCenter: parent.horizontalCenter
            z: 11
            colors: appWallpaper.colors

            onTextChanged: {
                if (appWallpaper.showing && appWallpaper.cardVisible) {
                    appWallpaper.hideCursor(200)
                }
            }
            onSearchInteracted: {
                if (appWallpaper.showing && appWallpaper.cardVisible) {
                    appWallpaper.hideCursor(200)
                }
            }

            enabled: !settingsPanel.showing
            onAccepted: {
                var currentView = appWallpaper.isSliceMode ? sliceListView : (appWallpaper.isHexMode ? hexListView : thumbGridView)
                if (currentView.currentIndex >= 0 && appWallpaper.wallpaperResults.values && currentView.currentIndex < appWallpaper.wallpaperResults.values.length) {
                    var wall = appWallpaper.wallpaperResults.values ? appWallpaper.wallpaperResults.values[currentView.currentIndex] : null
                    CaelestiaApi.visuals.wallpaper.setWallpaper(wall.path)
                    appWallpaper.closeRequested()
                }
            }
            onEscapePressed: appWallpaper.closeRequested()
        }

        IconButton {
            id: floatingSettingsBtn
            icon: "settings"
            type: IconButton.Tonal
            anchors.left: topSearchBar.right
            anchors.leftMargin: 16
            anchors.verticalCenter: topSearchBar.verticalCenter
            z: 11
            onClicked: settingsPanel.showing = !settingsPanel.showing
        }

        Rectangle {
          anchors.fill: parent
          z: -1
          color: Qt.rgba(appWallpaper.colors.surfaceContainer.r,
                         appWallpaper.colors.surfaceContainer.g,
                         appWallpaper.colors.surfaceContainer.b, 0.95)
          radius: 20
          clip: true
          opacity: 0 // hidden per user request
        }
      }
    }

    Views.SliceView {
        id: sliceListView
        visible: appWallpaper.cardVisible && appWallpaper.isSliceMode
        enabled: !settingsPanel.showing
        anchors.top: cardContainer.top
        anchors.topMargin: appWallpaper.topBarHeight
        anchors.bottom: cardContainer.bottom
        anchors.bottomMargin: appWallpaper.bottomBarHeight
        anchors.horizontalCenter: parent.horizontalCenter
        
        colors: appWallpaper.colors
        model: appWallpaper.isSliceMode ? appWallpaper.wallpaperResults : null
        visibleCount: appWallpaper.visibleCount
        expandedWidth: appWallpaper.expandedWidth
        sliceWidth: appWallpaper.sliceWidth
        sliceSpacing: appWallpaper.sliceSpacing
        skewOffset: appWallpaper.skewOffset

        focus: appWallpaper.showing && !settingsPanel.showing
        onVisibleChanged: {
            if (visible && !settingsPanel.showing) forceActiveFocus()
        }

        Connections {
            target: appWallpaper
            function onShowingChanged() {
                if (appWallpaper.showing && appWallpaper.isSliceMode) {
                    sliceListView.forceActiveFocus()
                }
            }
        }

        onCycleNext: step => appWallpaper.cycleNext(step)
        onCyclePrev: step => appWallpaper.cyclePrev(step)
        onWallpaperSelected: path => {
            CaelestiaApi.visuals.wallpaper.setWallpaper(path)
            appWallpaper.closeRequested()
        }
        onCurrentIndexChanged: {
            if (appWallpaper.showing && appWallpaper.cardVisible) {
                previewTimer.restart()
            }
        }
        onEscapePressed: {
            if (topSearchBar.text !== "") {
                topSearchBar.text = ""
            } else {
                appWallpaper.closeRequested()
            }
        }
        onAppendSearchText: text => {
            appWallpaper.hideCursor(200)
            topSearchBar.appendSearchText(text)
        }
        onBackspaceSearchText: () => {
            appWallpaper.hideCursor(200)
            topSearchBar.backspaceSearchText()
        }
        onInteractionStarted: interactionBlockerTimer.restart()
    }

    Views.HexView {
        id: hexListView
        visible: appWallpaper.cardVisible && appWallpaper.isHexMode
        enabled: !settingsPanel.showing
        anchors.top: cardContainer.top
        anchors.topMargin: appWallpaper.topBarHeight
        anchors.bottom: cardContainer.bottom
        anchors.bottomMargin: appWallpaper.bottomBarHeight
        anchors.left: cardContainer.left
        anchors.right: cardContainer.right
        
        focus: appWallpaper.showing && visible && !settingsPanel.showing
        
        colors: appWallpaper.colors
        wallpaperData: appWallpaper.wallpaperResults.values
        model: appWallpaper.isHexMode ? Math.ceil((appWallpaper.wallpaperResults.values ? appWallpaper.wallpaperResults.values.length : 0) / Math.max(1, Config.hexRows)) : 0
        
        onCycleNext: step => appWallpaper.cycleNext(step)
        onCyclePrev: step => appWallpaper.cyclePrev(step)
        onWallpaperSelected: path => {
            CaelestiaApi.visuals.wallpaper.setWallpaper(path)
            appWallpaper.closeRequested()
        }
        on_SelectedColChanged: {
            if (appWallpaper.showing && appWallpaper.cardVisible) {
                previewTimer.restart()
            }
        }
        on_SelectedRowChanged: {
            if (appWallpaper.showing && appWallpaper.cardVisible) {
                previewTimer.restart()
            }
        }
        onEscapePressed: {
            if (topSearchBar.text !== "") {
                topSearchBar.text = ""
            } else {
                appWallpaper.closeRequested()
            }
        }
        onAppendSearchText: text => {
            appWallpaper.hideCursor(200)
            topSearchBar.appendSearchText(text)
        }
        onBackspaceSearchText: () => {
            appWallpaper.hideCursor(200)
            topSearchBar.backspaceSearchText()
        }
        onInteractionStarted: interactionBlockerTimer.restart()
    }

    // Hex View edge hover autoscroll regions (invisible, active only in Hex View)
    Item {
        id: hexEdgeRegions
        visible: appWallpaper.showing && appWallpaper.cardVisible && appWallpaper.isHexMode && (typeof settingsPanel === "undefined" || !settingsPanel.showing)
        anchors.fill: parent
        z: 1000

        Timer {
            id: hexLeftScrollTimer
            interval: 100
            repeat: true
            onTriggered: {
                appWallpaper.cyclePrev(1, false)
            }
        }

        Timer {
            id: hexRightScrollTimer
            interval: 100
            repeat: true
            onTriggered: {
                appWallpaper.cycleNext(1, false)
            }
        }

        // Left invisible region
        Item {
            id: hexLeftContainer
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 150
            z: 1000

            HoverHandler {
                id: hexLeftHover
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad | PointerDevice.Stylus
                onHoveredChanged: {
                    if (hovered) {
                        appWallpaper.cyclePrev(1, false)
                        hexLeftScrollTimer.restart()
                    } else if (!hexLeftMouse.containsMouse) {
                        hexLeftScrollTimer.stop()
                    }
                }
            }

            MouseArea {
                id: hexLeftMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.ArrowCursor
                onEntered: {
                    appWallpaper.cyclePrev(1, false)
                    hexLeftScrollTimer.restart()
                }
                onExited: {
                    if (!hexLeftHover.hovered) {
                        hexLeftScrollTimer.stop()
                    }
                }
                onPositionChanged: {
                    if (!hexLeftScrollTimer.running) {
                        hexLeftScrollTimer.restart()
                    }
                }
            }
        }

        // Right invisible region
        Item {
            id: hexRightContainer
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 150
            z: 1000

            HoverHandler {
                id: hexRightHover
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad | PointerDevice.Stylus
                onHoveredChanged: {
                    if (hovered) {
                        appWallpaper.cycleNext(1, false)
                        hexRightScrollTimer.restart()
                    } else if (!hexRightMouse.containsMouse) {
                        hexRightScrollTimer.stop()
                    }
                }
            }

            MouseArea {
                id: hexRightMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.ArrowCursor
                onEntered: {
                    appWallpaper.cycleNext(1, false)
                    hexRightScrollTimer.restart()
                }
                onExited: {
                    if (!hexRightHover.hovered) {
                        hexRightScrollTimer.stop()
                    }
                }
                onPositionChanged: {
                    if (!hexRightScrollTimer.running) {
                        hexRightScrollTimer.restart()
                    }
                }
            }
        }

        Connections {
            target: appWallpaper
            function onShowingChanged() {
                if (!appWallpaper.showing) {
                    hexLeftScrollTimer.stop()
                    hexRightScrollTimer.stop()
                }
            }
            function onCardVisibleChanged() {
                if (!appWallpaper.cardVisible) {
                    hexLeftScrollTimer.stop()
                    hexRightScrollTimer.stop()
                }
            }
        }
    }

    // Thumb/Grid View edge hover autoscroll regions (invisible, active only in Grid View)
    Item {
        id: thumbEdgeRegions
        visible: appWallpaper.showing && appWallpaper.cardVisible && appWallpaper.isGridMode && (typeof settingsPanel === "undefined" || !settingsPanel.showing)
        anchors.fill: parent
        z: 1000

        readonly property int _stepCount: Math.max(1, Config.gridColumns || 4)

        Timer {
            id: thumbTopScrollTimer
            interval: 300
            repeat: true
            onTriggered: {
                appWallpaper.cyclePrev(thumbEdgeRegions._stepCount, false)
            }
        }

        Timer {
            id: thumbBottomScrollTimer
            interval: 300
            repeat: true
            onTriggered: {
                appWallpaper.cycleNext(thumbEdgeRegions._stepCount, false)
            }
        }

        // Top invisible region (prev)
        Item {
            id: thumbTopContainer
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 120
            z: 1000

            HoverHandler {
                id: thumbTopHover
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad | PointerDevice.Stylus
                onHoveredChanged: {
                    if (hovered) {
                        appWallpaper.cyclePrev(thumbEdgeRegions._stepCount, false)
                        thumbTopScrollTimer.restart()
                    } else if (!thumbTopMouse.containsMouse) {
                        thumbTopScrollTimer.stop()
                    }
                }
            }

            MouseArea {
                id: thumbTopMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.ArrowCursor
                onEntered: {
                    appWallpaper.cyclePrev(thumbEdgeRegions._stepCount, false)
                    thumbTopScrollTimer.restart()
                }
                onExited: {
                    if (!thumbTopHover.hovered) {
                        thumbTopScrollTimer.stop()
                    }
                }
                onPositionChanged: {
                    if (!thumbTopScrollTimer.running) {
                        thumbTopScrollTimer.restart()
                    }
                }
            }
        }

        // Bottom invisible region (next)
        Item {
            id: thumbBottomContainer
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 120
            z: 1000

            HoverHandler {
                id: thumbBottomHover
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad | PointerDevice.Stylus
                onHoveredChanged: {
                    if (hovered) {
                        appWallpaper.cycleNext(thumbEdgeRegions._stepCount, false)
                        thumbBottomScrollTimer.restart()
                    } else if (!thumbBottomMouse.containsMouse) {
                        thumbBottomScrollTimer.stop()
                    }
                }
            }

            MouseArea {
                id: thumbBottomMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.ArrowCursor
                onEntered: {
                    appWallpaper.cycleNext(thumbEdgeRegions._stepCount, false)
                    thumbBottomScrollTimer.restart()
                }
                onExited: {
                    if (!thumbBottomHover.hovered) {
                        thumbBottomScrollTimer.stop()
                    }
                }
                onPositionChanged: {
                    if (!thumbBottomScrollTimer.running) {
                        thumbBottomScrollTimer.restart()
                    }
                }
            }
        }

        Connections {
            target: appWallpaper
            function onShowingChanged() {
                if (!appWallpaper.showing) {
                    thumbTopScrollTimer.stop()
                    thumbBottomScrollTimer.stop()
                }
            }
            function onCardVisibleChanged() {
                if (!appWallpaper.cardVisible) {
                    thumbTopScrollTimer.stop()
                    thumbBottomScrollTimer.stop()
                }
            }
        }
    }

    Views.ThumbGridView {
        id: thumbGridView
        visible: appWallpaper.cardVisible && appWallpaper.isGridMode
        enabled: !settingsPanel.showing
        anchors.top: cardContainer.top
        anchors.topMargin: appWallpaper.topBarHeight
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.horizontalCenterOffset: appWallpaper._gridCellGap / 2
        width: appWallpaper._gridTotalW
        height: appWallpaper._gridTotalH
        
        focus: appWallpaper.showing && visible && !settingsPanel.showing
        
        colors: appWallpaper.colors
        model: appWallpaper.isGridMode ? appWallpaper.wallpaperResults : null
        
        onCycleNext: step => appWallpaper.cycleNext(step)
        onCyclePrev: step => appWallpaper.cyclePrev(step)
        onWallpaperSelected: path => {
            CaelestiaApi.visuals.wallpaper.setWallpaper(path)
            appWallpaper.closeRequested()
        }
        onCurrentIndexChanged: {
            if (appWallpaper.showing && appWallpaper.cardVisible) {
                previewTimer.restart()
            }
        }
        onEscapePressed: {
            if (topSearchBar.text !== "") {
                topSearchBar.text = ""
            } else {
                appWallpaper.closeRequested()
            }
        }
        onAppendSearchText: text => {
            appWallpaper.hideCursor(200)
            topSearchBar.appendSearchText(text)
        }
        onBackspaceSearchText: () => {
            appWallpaper.hideCursor(200)
            topSearchBar.backspaceSearchText()
        }
        onInteractionStarted: interactionBlockerTimer.restart()
    }

    Components.FilterRow {
        id: sourceFilterRow
        anchors.bottom: cardContainer.bottom
        anchors.bottomMargin: 25
        anchors.horizontalCenter: parent.horizontalCenter
        visible: appWallpaper.cardVisible
        enabled: !settingsPanel.showing
        z: 11
    }

    Components.SettingsPanel {
        id: settingsPanel
        anchors.fill: parent
        z: 2000
        colors: appWallpaper.colors
    }

    Connections {
        target: settingsPanel
        function onShowingChanged() {
            if (!settingsPanel.showing && appWallpaper.showing) {
                if (appWallpaper.isSliceMode) sliceListView.forceActiveFocus()
                else if (appWallpaper.isHexMode) hexListView.forceActiveFocus()
                else if (appWallpaper.isGridMode) thumbGridView.forceActiveFocus()
            }
        }
    }

    FocusScope {
        id: funnelScope
        visible: !appWallpaper.isMainScreen && !settingsPanel.showing
        enabled: !appWallpaper.isMainScreen && !settingsPanel.showing
        anchors.fill: parent
        focus: !appWallpaper.isMainScreen && !settingsPanel.showing
        activeFocusOnTab: false

        Component.onCompleted: { if (!appWallpaper.isMainScreen && !settingsPanel.showing) forceActiveFocus() }
        onActiveFocusChanged: { if (!activeFocus && !appWallpaper.isMainScreen && !settingsPanel.showing) forceActiveFocus() }

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
                appWallpaper.closeRequested()
                event.accepted = true
                return
            }
            if (event.text && event.text.length > 0 && !event.modifiers) {
                var c = event.text.charCodeAt(0)
                if (c >= 32 && c < 127) {
                    appWallpaper.hideCursor(200)
                    topSearchBar.appendSearchText(event.text)
                    event.accepted = true
                    return
                }
            }
            if (event.key === Qt.Key_Backspace) {
                appWallpaper.hideCursor(200)
                topSearchBar.backspaceSearchText()
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                var currentView = appWallpaper.isSliceMode ? sliceListView : (appWallpaper.isHexMode ? hexListView : thumbGridView)
                if (currentView.currentIndex >= 0 && appWallpaper.wallpaperResults.values && currentView.currentIndex < appWallpaper.wallpaperResults.values.length) {
                    var app = appWallpaper.wallpaperResults.values ? appWallpaper.wallpaperResults.values[currentView.currentIndex] : null
                    CaelestiaApi.visuals.wallpaper.setWallpaper(app.path)
                    appWallpaper.closeRequested()
                }
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Left) {
                appWallpaper.cyclePrev(1)
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Right) {
                appWallpaper.cycleNext(1)
                event.accepted = true
                return
            }
        }


        HoverHandler {
            acceptedDevices: PointerDevice.AllDevices
            onHoveredChanged: if (hovered) funnelScope.forceActiveFocus()
        }
    }

    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: function(event) {
            appWallpaper.hideCursor(100)
        }
    }

    MouseArea {
        id: hideCursorArea
        anchors.fill: parent
        z: 99999
        visible: appWallpaper.hideMouse
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        cursorShape: Qt.BlankCursor

        property real lastX: -1
        property real lastY: -1

        onVisibleChanged: {
            if (visible) {
                lastX = -1
                lastY = -1
            }
        }

        onPositionChanged: function(mouse) {
            if (!appWallpaper.hideMouse) return

            if (lastX < 0 || lastY < 0) {
                lastX = mouse.x
                lastY = mouse.y
                return
            }

            var dx = Math.abs(mouse.x - lastX)
            var dy = Math.abs(mouse.y - lastY)

            if (!appWallpaper.canUnhideMouse) {
                lastX = mouse.x
                lastY = mouse.y
                return
            }

            if (dx * dx + dy * dy > 25) {
                appWallpaper.hideMouse = false
                appWallpaper.canUnhideMouse = false
                appWallpaper.centerCursor()
            }
        }
    }
}
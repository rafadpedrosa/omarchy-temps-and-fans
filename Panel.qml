import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
  id: root
  moduleName: "stevemcqueen.thermals"
  ipcTarget: "stevemcqueen.thermals"
  manageIpc: false

  property var snapshot: ({ ok: false })
  property bool busy: false
  property string notice: ""
  property bool noticeError: false
  property int cpuPreview: snapshot.ok ? snapshot.fans.cpu.duty : 25
  property int casePreview: snapshot.ok ? snapshot.fans.case.duty : 40
  property string focusSection: "cpuFan"
  property bool cursorActive: false
  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("thermalsctl").toString().replace("file://", ""))
  readonly property real cpuTemp: snapshot.ok && snapshot.cpu.temp !== null ? snapshot.cpu.temp : -1
  readonly property bool isHot: cpuTemp >= 85
  readonly property bool manualMode: snapshot.ok && (snapshot.fans.cpu.mode === "manual" || snapshot.fans.case.mode === "manual")

  function c(value) { return value === null || value === undefined || value < 0 ? "--" : Math.round(value) + "°C" }
  function ghz(value) { return value ? (value / 1000).toFixed(2) + " GHz" : "--" }
  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }
  function runAction(args) {
    if (actionProc.running) return
    notice = ""
    busy = true
    actionProc.command = [helperPath].concat(args)
    actionProc.running = true
  }
  function moveCursor(dy) {
    var sections = ["cpuFan", "caseFan", "restore", "save"]
    var index = Math.max(0, sections.indexOf(focusSection))
    focusSection = sections[Math.max(0, Math.min(sections.length - 1, index + (dy > 0 ? 1 : -1)))]
  }
  function adjustCurrent(dx) {
    if (focusSection === "cpuFan") {
      cpuPreview = Math.max(5, Math.min(100, cpuPreview + dx * 5))
      runAction(["manual", "cpu", String(cpuPreview)])
    } else if (focusSection === "caseFan") {
      casePreview = Math.max(5, Math.min(100, casePreview + dx * 5))
      runAction(["manual", "case", String(casePreview)])
    }
  }
  function activateCurrent() {
    if (focusSection === "restore") runAction(["restore"])
    else if (focusSection === "save") runAction(["save", String(cpuPreview), String(casePreview)])
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      cursorActive = false
      focusSection = "cpuFan"
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Timer {
    interval: root.opened ? 2000 : 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: statusProc
    command: [root.helperPath, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text || "{}"))
          if (data.ok) {
            var wasDragging = cpuFanRow.dragging || caseFanRow.dragging
            root.snapshot = data
            if (!wasDragging && !root.busy) {
              root.cpuPreview = data.fans.cpu.duty
              root.casePreview = data.fans.case.duty
            }
          } else {
            root.notice = data.error || "Unable to read CoolerControl"
            root.noticeError = true
          }
        } catch (error) {
          root.notice = "Telemetry update failed: " + String(error)
          root.noticeError = true
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") {
        root.notice = String(text).trim()
        root.noticeError = true
      }
    }
  }

  Component.onCompleted: root.refresh()

  IpcHandler {
    target: "stevemcqueen.thermals"
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function state(): string { return JSON.stringify(root.snapshot) }
    function message(): string { return root.notice }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text || "{}"))
          root.notice = data.message || data.error || "Fan control updated"
          root.noticeError = !data.ok
        } catch (error) {
          root.notice = "Fan control did not return a valid response"
          root.noticeError = true
        }
      }
    }
    onRunningChanged: if (!running) {
      root.busy = false
      root.refresh()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰔏"
    active: root.isHot
    useActiveColor: true
    tooltipText: root.snapshot.ok
      ? "CPU " + root.c(root.snapshot.cpu.temp) + " · " + root.snapshot.fans.cpu.rpm + " RPM"
      : "Thermals & Fans"
    onPressed: function(mouseButton) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjustCurrent(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCurrent()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          PanelHero {
            title: "Thermals & Fans"
            meta: root.snapshot.ok
              ? (root.snapshot.backend !== "direct" ? "Telemetry only · install control service" : (root.manualMode ? "Manual · held until restored" : "Optimized · direct hwmon"))
              : "Reading hardware sensors"
            detail: root.c(root.cpuTemp)
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            iconComponent: Component {
              Text {
                text: "󰔏"
                color: root.isHot ? root.bar.urgent : root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          PanelSeparator { foreground: root.bar.foreground }

          Column {
            width: parent.width
            spacing: Style.space(7)
            PanelSectionHeader { text: "TEMPERATURES"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }
            StatRow { label: "CPU Tctl"; value: root.snapshot.ok ? root.c(root.snapshot.cpu.temp) : "--" }
            Repeater {
              model: root.snapshot.ok ? root.snapshot.gpus : []
              Column {
                required property var modelData
                property var gpu: modelData
                width: panelColumn.width
                spacing: Style.space(4)
                Text { text: parent.gpu.name; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
                Repeater {
                  model: parent.gpu.temps
                  StatRow { required property var modelData; label: "  " + modelData.label; value: root.c(modelData.value) }
                }
                StatRow { visible: parent.gpu.load !== null; label: "  Load"; value: parent.gpu.load !== null ? parent.gpu.load + "%" : "--" }
                StatRow {
                  visible: parent.gpu.fan_rpm !== null
                  label: "  Fan"
                  value: parent.gpu.fan_rpm + " RPM" + (parent.gpu.fan_duty !== null ? "  ·  " + parent.gpu.fan_duty + "%" : "")
                }
              }
            }
            StatRow { label: "Memory modules"; value: root.snapshot.ok && root.snapshot.memory.length ? root.snapshot.memory.map(root.c).join("  ·  ") : "--" }
            Repeater {
              model: root.snapshot.ok ? root.snapshot.nvmes : []
              StatRow { required property var modelData; label: modelData.name; value: root.c(modelData.temp) }
            }
            StatRow { label: "Motherboard sensors"; value: root.snapshot.ok ? root.c(root.snapshot.board.temp1) + "  ·  " + root.c(root.snapshot.board.temp2) : "--" }
          }

          PanelSeparator { foreground: root.bar.foreground }

          Column {
            width: parent.width
            spacing: Style.space(7)
            PanelSectionHeader { text: "CPU STATE"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }
            StatRow { label: "Usage"; value: root.snapshot.ok ? root.snapshot.cpu.load.toFixed(1) + "%" : "--" }
            StatRow { label: "Clock average"; value: root.snapshot.ok ? root.ghz(root.snapshot.cpu.freq_avg) : "--" }
            StatRow { label: "Clock range"; value: root.snapshot.ok ? root.ghz(root.snapshot.cpu.freq_min) + " – " + root.ghz(root.snapshot.cpu.freq_max) : "--" }
            StatRow { label: "Package power"; value: root.snapshot.ok && root.snapshot.cpu.power !== null ? root.snapshot.cpu.power.toFixed(1) + " W" : "--" }
          }

          PanelSeparator { foreground: root.bar.foreground }

          Column {
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: fanHeader.implicitHeight
              PanelSectionHeader { id: fanHeader; text: "FAN CONTROL"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily; anchors.left: parent.left }
              Text {
                anchors.right: parent.right
                text: root.busy ? "APPLYING…" : (root.snapshot.backend !== "direct" ? "READ ONLY" : (root.manualMode ? "MANUAL" : "OPTIMIZED"))
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            FanSlider {
              id: cpuFanRow
              title: "CPU fan"
              duty: root.cpuPreview
              rpm: root.snapshot.ok ? root.snapshot.fans.cpu.rpm : 0
              minimum: 5
              hasCursor: root.cursorActive && root.focusSection === "cpuFan"
              onHovered: function() { root.cursorActive = true; root.focusSection = "cpuFan" }
              onPreviewChanged: function(value) { root.cpuPreview = value }
              onCommitted: function(value) { root.cpuPreview = value; root.runAction(["manual", "cpu", String(value)]) }
            }

            FanSlider {
              id: caseFanRow
              title: "Case fan"
              duty: root.casePreview
              rpm: root.snapshot.ok ? root.snapshot.fans.case.rpm : 0
              minimum: 5
              hasCursor: root.cursorActive && root.focusSection === "caseFan"
              onHovered: function() { root.cursorActive = true; root.focusSection = "caseFan" }
              onPreviewChanged: function(value) { root.casePreview = value }
              onCommitted: function(value) { root.casePreview = value; root.runAction(["manual", "case", String(value)]) }
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)
              Button {
                Layout.fillWidth: true
                text: "Restore optimized"
                iconText: "󰑐"
                bordered: true
                enabled: root.snapshot.ok && root.snapshot.backend === "direct" && !root.busy
                hasCursor: root.cursorActive && root.focusSection === "restore"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onHovered: function(on) { if (on) { root.cursorActive = true; root.focusSection = "restore" } }
                onClicked: root.runAction(["restore"])
              }
              Button {
                Layout.fillWidth: true
                text: "Save as optimized"
                iconText: "󰆓"
                bordered: true
                enabled: root.snapshot.ok && root.snapshot.backend === "direct" && !root.busy
                hasCursor: root.cursorActive && root.focusSection === "save"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                tooltipText: "Use these duties as the flat 0–85°C baselines"
                onHovered: function(on) { if (on) { root.cursorActive = true; root.focusSection = "save" } }
                onClicked: root.runAction(["save", String(root.cpuPreview), String(root.casePreview)])
              }
            }

            Text {
              width: parent.width
              visible: root.notice !== ""
              text: root.notice
              color: root.noticeError ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.35)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            Text {
              width: parent.width
              text: "Manual settings stay active until you restore the optimized profile. At 85°C they restore automatically for safety. Saved baselines stay flat through 85°C."
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }
          }
        }
      }
    }
  }

  component StatRow: Item {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : 0
    implicitHeight: Math.max(statLabel.implicitHeight, statValue.implicitHeight)
    Text { id: statLabel; anchors.left: parent.left; text: parent.label; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.body }
    Text { id: statValue; anchors.right: parent.right; text: parent.value; color: Qt.darker(root.bar.foreground, 1.3); font.family: root.bar.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
  }

  component FanSlider: Column {
    id: fanControl
    property string title: ""
    property int duty: 0
    property int rpm: 0
    property int minimum: 5
    property bool hasCursor: false
    property alias dragging: fanSlider.dragging
    signal previewChanged(int value)
    signal committed(int value)
    signal hovered()
    width: parent ? parent.width : 0
    spacing: Style.space(3)
    Item {
      width: parent.width
      implicitHeight: Math.max(fanName.implicitHeight, fanValue.implicitHeight)
      Text { id: fanName; anchors.left: parent.left; text: fanControl.title; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
      Text { id: fanValue; anchors.right: parent.right; text: fanControl.duty + "%  ·  " + fanControl.rpm + " RPM"; color: Qt.darker(root.bar.foreground, 1.3); font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
    }
    CursorSurface {
      width: parent.width
      height: fanSlider.implicitHeight + Style.spacing.controlGap
      hasCursor: fanControl.hasCursor
      foreground: root.bar.foreground
      outline: true
      PanelSlider {
        id: fanSlider
        bar: root.bar
        anchors.fill: parent
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(6)
        minimum: fanControl.minimum
        maximum: 100
        step: 5
        integer: true
        tickCount: 5
        value: fanControl.duty
        enabled: root.snapshot.ok && root.snapshot.backend === "direct" && !root.busy && root.cpuTemp < 85
        onMoved: function(value) { fanControl.previewChanged(Math.round(value / 5) * 5) }
        onReleased: function(value) { fanControl.committed(Math.round(value / 5) * 5) }
      }
      HoverHandler { onHoveredChanged: if (hovered) fanControl.hovered() }
    }
  }
}

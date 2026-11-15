import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
  id: root
  moduleName: "thermals.fans"
  ipcTarget: "thermals.fans"
  manageIpc: false

  property var snapshot: ({ ok: false })
  property bool busy: false
  property string notice: ""
  property bool noticeError: false
  property int cpuPreview: snapshot.ok ? snapshot.fans.cpu.duty : 25
  property int casePreview: snapshot.ok ? snapshot.fans.case.duty : 40
  property string selectedPreset: snapshot.ok && snapshot.active_preset ? snapshot.active_preset : "silent"
  property string presetName: "Silent"
  property var editCurves: ({ cpu: [], case: [] })
  property bool editingDirty: false
  property bool curveEditorOpen: false
  readonly property var presetIds: ["default", "full", "silent", "custom"]
  property string focusSection: "fan"
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
  function preset(id) { return snapshot.presets && snapshot.presets[id] ? snapshot.presets[id] : ({ name: id, cpu: [], case: [] }) }
  function syncPresetEditor() {
    var selected = preset(selectedPreset)
    presetName = selected.name || selectedPreset
    editCurves = { cpu: JSON.parse(JSON.stringify(selected.cpu || [])), case: JSON.parse(JSON.stringify(selected.case || [])) }
  }
  function selectPreset(id) {
    selectedPreset = id
    editingDirty = false
    syncPresetEditor()
    runAction(["select", id])
  }
  function changeCurvePoint(role, index, temperature, duty) {
    var next = { cpu: JSON.parse(JSON.stringify(editCurves.cpu || [])), case: JSON.parse(JSON.stringify(editCurves.case || [])) }
    next[role][index] = [Math.round(temperature), Math.round(duty)]
    editCurves = next
    editingDirty = true
  }
  function addCurvePoint(role) {
    var next = { cpu: JSON.parse(JSON.stringify(editCurves.cpu || [])), case: JSON.parse(JSON.stringify(editCurves.case || [])) }
    var points = next[role]
    if (points.length >= 8) return
    var previous = points.length ? points[points.length - 1] : [0, 25]
    var temperature = Math.min(100, Number(previous[0]) + 5)
    if (temperature <= Number(previous[0])) return
    points.push([temperature, Number(previous[1])])
    editCurves = next
    editingDirty = true
  }
  function savePreset() {
    runAction(["preset-save", selectedPreset, presetName, JSON.stringify(editCurves.cpu), JSON.stringify(editCurves.cpu)])
    editingDirty = false
  }
  function runAction(args) {
    if (actionProc.running) return
    notice = ""
    busy = true
    actionProc.command = [helperPath].concat(args)
    actionProc.running = true
  }
  function moveCursor(dy) {
    var sections = ["fan", "restore"]
    var index = Math.max(0, sections.indexOf(focusSection))
    focusSection = sections[Math.max(0, Math.min(sections.length - 1, index + (dy > 0 ? 1 : -1)))]
  }
  function adjustCurrent(dx) {
    if (focusSection === "fan") {
      cpuPreview = Math.max(5, Math.min(100, cpuPreview + dx * 5))
      runAction(["manual", "cpu", String(cpuPreview)])
    }
  }
  function activateCurrent() {
    if (focusSection === "restore") selectPreset(selectedPreset)
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      cursorActive = false
      focusSection = "fan"
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
            var wasDragging = cpuFanRow.dragging
            root.snapshot = data
            if (!root.editingDirty) root.syncPresetEditor()
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
    target: "thermals.fans"
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
              ? (root.snapshot.backend !== "direct" ? "Telemetry only · install control service" : (root.manualMode ? "Manual · held until restored" : (root.preset(root.selectedPreset).name || "Profile") + " · direct EC"))
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
              title: "Fan"
              duty: root.cpuPreview
              rpm: root.snapshot.ok ? root.snapshot.fans.cpu.rpm : 0
              minimum: 5
              hasCursor: root.cursorActive && root.focusSection === "fan"
              onHovered: function() { root.cursorActive = true; root.focusSection = "fan" }
              onPreviewChanged: function(value) { root.cpuPreview = value }
              onCommitted: function(value) { root.cpuPreview = value; root.runAction(["manual", "cpu", String(value)]) }
            }

            PanelSectionHeader { text: "PROFILE"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }
            Flow {
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: root.presetIds
                Button {
                  required property string modelData
                  text: root.preset(modelData).name
                  selected: root.selectedPreset === modelData
                  bordered: true
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.selectPreset(modelData)
                }
              }
            }

            Button {
              width: parent.width
              text: root.curveEditorOpen ? "Hide curve editor" : "Edit fan curves"
              bordered: true
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.curveEditorOpen = !root.curveEditorOpen
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              visible: root.curveEditorOpen
              RowLayout {
                width: parent.width
                spacing: Style.space(8)
                TextField {
                  id: presetNameField
                  Layout.fillWidth: true
                  text: root.presetName
                  color: root.bar.foreground
                  placeholderText: "Preset name"
                  selectByMouse: true
                  onTextChanged: root.presetName = text
                }
                Button {
                  text: "Save profile"
                  iconText: "󰆓"
                  bordered: true
                  enabled: root.snapshot.ok && root.snapshot.backend === "direct" && !root.busy && root.presetName.trim() !== ""
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.savePreset()
                }
              }
              CurveEditor { role: "cpu"; title: "Fan curve"; points: root.editCurves.cpu }
              Text {
                width: parent.width
                text: "Each curve is interpolated between points. Keep the first point at 0°C; later temperatures must increase."
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)
              Button {
                Layout.fillWidth: true
                text: "Restore selected"
                iconText: "󰑐"
                bordered: true
                enabled: root.snapshot.ok && root.snapshot.backend === "direct" && !root.busy
                hasCursor: root.cursorActive && root.focusSection === "restore"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onHovered: function(on) { if (on) { root.cursorActive = true; root.focusSection = "restore" } }
                onClicked: root.selectPreset(root.selectedPreset)
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
              text: "Manual settings stay active until you restore a profile. At 85°C the selected profile takes over automatically for safety."
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

  component CurveEditor: Column {
    id: curveEditor
    property string role: "cpu"
    property string title: "Curve"
    property var points: []
    width: parent ? parent.width : 0
    spacing: Style.space(5)
    Text { text: curveEditor.title; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
    Repeater {
      model: curveEditor.points.length
      Column {
        required property int index
        property var point: curveEditor.points[index]
        width: curveEditor.width
        spacing: Style.space(2)
        RowLayout {
          width: parent.width
          height: Style.space(32)
          spacing: Style.space(3)
          Text {
            text: "Point " + (index + 1)
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            Layout.preferredWidth: Style.space(54)
          }
          RowLayout {
            spacing: Style.space(5)
            TextField {
              id: temperatureField
              Layout.preferredWidth: Style.space(84)
              Layout.minimumWidth: Style.space(84)
              Layout.maximumWidth: Style.space(84)
              Layout.preferredHeight: Style.space(32)
              Layout.minimumHeight: Style.space(32)
              text: String(point[0])
              color: root.bar.foreground
              enabled: index > 0
              selectByMouse: true
              horizontalAlignment: TextInput.AlignHCenter
              validator: IntValidator { bottom: index > 0 ? curveEditor.points[index - 1][0] + 1 : 0; top: index + 1 < curveEditor.points.length ? curveEditor.points[index + 1][0] - 1 : 100 }
              onEditingFinished: {
                var value = Number(text)
                if (!isNaN(value)) root.changeCurvePoint(curveEditor.role, index, value, point[1])
              }
            }
            Text { text: "°C"; color: Qt.darker(root.bar.foreground, 1.35); font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption }
          }
          RowLayout {
            spacing: Style.space(5)
            TextField {
              id: dutyField
              Layout.preferredWidth: Style.space(84)
              Layout.minimumWidth: Style.space(84)
              Layout.maximumWidth: Style.space(84)
              Layout.preferredHeight: Style.space(32)
              Layout.minimumHeight: Style.space(32)
              text: String(point[1])
              color: root.bar.foreground
              selectByMouse: true
              horizontalAlignment: TextInput.AlignHCenter
              validator: IntValidator { bottom: 5; top: 100 }
              onEditingFinished: {
                var value = Number(text)
                if (!isNaN(value)) root.changeCurvePoint(curveEditor.role, index, point[0], value)
              }
            }
            Text { text: "%"; color: Qt.darker(root.bar.foreground, 1.35); font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption }
          }
        }
      }
    }
    Button {
      width: curveEditor.width
      text: "Add point"
      bordered: true
      enabled: curveEditor.points.length < 8 && curveEditor.points.length > 0 && curveEditor.points[curveEditor.points.length - 1][0] < 100
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
      onClicked: root.addCurvePoint(curveEditor.role)
    }
  }
}

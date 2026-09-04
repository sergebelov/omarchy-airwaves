import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "io.github.sergebelov.airwaves"

  // Enabling this plugin disables the first-party omarchy.media, so its service
  // is not mounted; use our own copy, falling back to the stock one only if the
  // two somehow run side by side.
  readonly property var mediaService: (bar?.shell?.serviceFor("io.github.sergebelov.airwaves")
    || bar?.shell?.serviceFor("omarchy.media")) ?? null
  readonly property var activePlayer: mediaService ? mediaService.activePlayer : null
  readonly property var sourcePlayers: mediaService ? mediaService.sourcePlayers : []

  readonly property bool hasMedia: activePlayer !== null && (activePlayer.trackTitle || activePlayer.trackArtist)
  readonly property bool isPlaying: activePlayer ? activePlayer.isPlaying === true : false
  readonly property string title: activePlayer ? (activePlayer.trackTitle || "") : ""
  readonly property string artist: activePlayer ? (activePlayer.trackArtist || "") : ""

  property bool popupOpen: false
  function close() { popupOpen = false }


  // Same fill roles the audio panel uses for its device rows.
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  // ---- OwnTone -------------------------------------------------------------
  // MPRIS (via mpd-mpris) can transport-control but knows nothing about AirPlay
  // routing or the station library, so those talk to OwnTone's REST API. curl in
  // a Process is the house idiom; the shell uses no XMLHttpRequest anywhere.
  // Per-install configuration, declared in manifest.json's barWidget.schema so
  // it is editable from the bar settings UI rather than baked into the source.
  readonly property string owntoneApi: String(setting("apiBase", "http://localhost:3689/api"))
  readonly property string stationsPlaylistName: String(setting("stationsPlaylist", "radio"))
  readonly property string stationsFile: String(setting("stationsFile", ""))
  readonly property int pollIntervalMs: Math.max(1, Number(setting("pollIntervalSec", 4))) * 1000

  // Resolved by playlist NAME at runtime: OwnTone assigns playlist ids per
  // library, so they differ on every install and cannot be hardcoded.
  property int stationPlaylistId: -1
  property bool owntoneReachable: false

  property var outputs: []
  property var stations: []

  readonly property var activeOutput: {
    for (var i = 0; i < outputs.length; i++)
      if (outputs[i] && outputs[i].selected) return outputs[i]
    return null
  }

  function refresh() { refreshPlaylists(); refreshOutputs(); refreshStations(); refreshNowPlaying() }
  function refreshPlaylists() { if (!playlistsProc.running) playlistsProc.running = true }
  function refreshNowPlaying() {
    if (!playerProc.running) playerProc.running = true
    if (!queueProc.running) queueProc.running = true
  }

  // MPRIS title strings are an unreliable way to tell which station is live
  // (stream metadata rewrites them mid-play). OwnTone can say exactly: the
  // player's item_id identifies a queue entry, whose track_id is the library id
  // the STATIONS rows are keyed on.
  property int playerItemId: -1
  property var queueItems: []
  readonly property int nowPlayingTrackId: {
    for (var i = 0; i < queueItems.length; i++)
      if (queueItems[i] && queueItems[i].id === playerItemId)
        return queueItems[i].track_id
    return -1
  }

  // PUT /api/update triggers a library rescan that can run for 10s+, during
  // which these endpoints legitimately return an empty list. Background polls
  // therefore keep the last-good list rather than blanking the popup; only an
  // explicit refresh (opening the popup) is allowed to clear it.
  property bool allowEmpty: false
  function applyStations(items) {
    if (items.length > 0 || allowEmpty || stations.length === 0) stations = items
  }
  function applyOutputs(items) {
    if (items.length > 0 || allowEmpty || outputs.length === 0) outputs = items
  }

  readonly property var pendingAuthOutput: {
    for (var i = 0; i < outputs.length; i++)
      if (outputs[i] && outputs[i].needs_auth_key === true) return outputs[i]
    return null
  }

  function verifyOutput(outputId, pin) {
    var clean = String(pin || "").trim()
    if (clean === "") return
    postProc.command = ["curl", "-fsS", "--max-time", "15", "-X", "POST",
      "-d", JSON.stringify({ "pin": clean }),
      root.owntoneApi + "/outputs/" + outputId + "/verification"]
    postProc.running = true
  }
  function refreshOutputs() { if (!outputsProc.running) outputsProc.running = true }
  function refreshStations() {
    if (stationPlaylistId < 0) return
    if (!stationsProc.running) stationsProc.running = true
  }

  function putJson(path, body) {
    writeProc.command = ["curl", "-fsS", "--max-time", "10", "-X", "PUT",
      "-d", JSON.stringify(body), root.owntoneApi + path]
    writeProc.running = true
  }

  function setOutputSelected(outputId, selected) { putJson("/outputs/" + outputId, { "selected": selected }) }
  function setOutputVolume(outputId, vol) {
    putJson("/outputs/" + outputId, { "volume": Math.max(0, Math.min(100, Math.round(vol))) })
  }

  // Replacing the queue is what "pick a station" means here: these are infinite
  // streams, so there is nothing to preserve behind them.
  function playStation(trackId) {
    postProc.command = ["curl", "-fsS", "--max-time", "15", "-X", "POST",
      root.owntoneApi + "/queue/items/add?uris=library:track:" + trackId + "&clear=true&playback=start"]
    postProc.running = true
  }

  // Play the URL now, and persist it to the m3u so it joins the list for good.
  // Resolved from the component's own location so the plugin stays relocatable.
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace("file://", "")

  // A rescan takes ~25s, so drop the row locally first and let the poll
  // reconcile; otherwise a removed station lingers for half a minute.
  function removeStation(trackId, url) {
    var next = []
    for (var i = 0; i < stations.length; i++)
      if (stations[i] && stations[i].id !== trackId) next.push(stations[i])
    stations = next
    removeProc.command = ["sh", root.pluginDir + "station-remove.sh",
      String(url || ""), root.stationsFile, root.owntoneApi]
    removeProc.running = true
  }

  function addStation(url) {
    var clean = String(url || "").trim()
    if (clean === "") return
    postProc.command = ["curl", "-fsS", "--max-time", "15", "-X", "POST",
      root.owntoneApi + "/queue/items/add?uris=" + encodeURIComponent(clean) + "&clear=true&playback=start"]
    postProc.running = true
    persistProc.command = ["sh", "-c",
      "M3U=\"$3\"; [ -n \"$M3U\" ] || M3U=\"$HOME/Music/radio.m3u\"; "
      + "{ echo \"#EXTINF:-1,$1\"; echo \"$1\"; } >> \"$M3U\"; "
      + "curl -fsS --max-time 10 -X PUT \"$2/update\" >/dev/null 2>&1",
      "sh", clean, root.owntoneApi, root.stationsFile]
    persistProc.running = true
  }

  Process {
    id: playlistsProc
    command: ["curl", "-fsS", "--max-time", "5", root.owntoneApi + "/library/playlists"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) { root.owntoneReachable = false; return }
        try {
          var d = JSON.parse(raw)
          var items = Array.isArray(d.items) ? d.items : []
          var want = root.stationsPlaylistName.toLowerCase()
          var found = -1
          for (var i = 0; i < items.length; i++)
            if (items[i] && String(items[i].name || "").toLowerCase() === want) {
              found = items[i].id
              break
            }
          root.stationPlaylistId = found
          root.owntoneReachable = true
          if (found >= 0) root.refreshStations()
        } catch (e) {
          root.owntoneReachable = false
        }
      }
    }
  }

  Process {
    id: outputsProc
    command: ["curl", "-fsS", "--max-time", "5", root.owntoneApi + "/outputs"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          var parsed = JSON.parse(raw)
          root.applyOutputs(Array.isArray(parsed.outputs) ? parsed.outputs : [])
        } catch (e) { /* keep last-good list rather than blanking the popup */ }
      }
    }
  }

  Process {
    id: stationsProc
    command: ["curl", "-fsS", "--max-time", "5",
      root.owntoneApi + "/library/playlists/" + root.stationPlaylistId + "/tracks"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          var parsed = JSON.parse(raw)
          root.applyStations(Array.isArray(parsed.items) ? parsed.items : [])
        } catch (e) { /* keep last-good list */ }
      }
    }
  }

  Process {
    id: playerProc
    command: ["curl", "-fsS", "--max-time", "5", root.owntoneApi + "/player"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "").trim())
          root.playerItemId = (d && d.item_id !== undefined) ? d.item_id : -1
        } catch (e) { /* keep last-good */ }
      }
    }
  }

  Process {
    id: queueProc
    command: ["curl", "-fsS", "--max-time", "5", root.owntoneApi + "/queue"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "").trim())
          if (Array.isArray(d.items)) root.queueItems = d.items
        } catch (e) { /* keep last-good */ }
      }
    }
  }

  Process { id: writeProc; onRunningChanged: if (!running) root.refreshOutputs() }
  Process { id: postProc; onRunningChanged: if (!running) root.refreshNowPlaying() }
  Process { id: persistProc; onRunningChanged: if (!running) root.refreshStations() }
  Process { id: removeProc; onRunningChanged: if (!running) root.refreshStations() }

  // Poll only while the popup is open; the bar icon needs none of this.
  Timer {
    interval: root.pollIntervalMs
    running: root.popupOpen
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onPopupOpenChanged: if (popupOpen) { allowEmpty = true; refresh(); allowEmptyReset.restart() }
  Timer { id: allowEmptyReset; interval: 1500; onTriggered: root.allowEmpty = false }

  // Always present. Hiding on `hasMedia` meant that once playback stopped the
  // icon disappeared, taking with it the only way to open the popup and start
  // something -- the widget is a control surface, not just a now-playing badge.
  visible: true
  implicitWidth: row.implicitWidth + Style.space(12)
  implicitHeight: barSize

  // One glyph in the bar. Playing vs paused reads as colour, not a second icon.
  Row {
    id: row
    anchors.centerIn: parent

    Text {
      id: glyph
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: "󰝚"
      color: root.isPlaying ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      Behavior on color {
        enabled: !root.bar || root.bar.foregroundAnimationEnabled
        ColorAnimation { duration: 160 }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (mouse.button === Qt.LeftButton) {
        root.popupOpen = !root.popupOpen
        return
      }
      if (!root.activePlayer) return
      if (mouse.button === Qt.MiddleButton) {
        if (root.mediaService) root.mediaService.runAction("next", false)
      } else if (mouse.button === Qt.RightButton) {
        if (root.mediaService) root.mediaService.runAction("playPause", false)
      }
    }
    onWheel: function(wheel) {
      if (!root.activePlayer) return
      if (wheel.angleDelta.y > 0 && root.mediaService) root.mediaService.runAction("previous", false)
      else if (wheel.angleDelta.y < 0 && root.mediaService) root.mediaService.runAction("next", false)
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.hasMedia
      ? (root.title + (root.artist ? " \u2014 " + root.artist : ""))
      : "Nothing playing")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // KeyboardPanel, not PopupCard: PopupCard is an xdg-popup child of the bar,
  // and Bar.qml sets WlrLayershell.keyboardFocus: None, so a TextField inside
  // one can never receive key events. KeyboardPanel is a PanelWindow that
  // primes WlrKeyboardFocus.Exclusive then drops to OnDemand, and exposes the
  // same anchorItem/owner/bar/open/contentWidth/Height API.
  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      // ---- Now playing ----
      Row {
        spacing: Style.space(10)
        width: parent.width

        BorderSurface {
          width: Style.space(48)
          height: Style.space(48)
          radius: Style.spacing.labelGap
          color: Style.normalFillFor(root.bar.foreground, Color.accent)
          borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)

          Image {
            id: artImage
            anchors.fill: parent
            anchors.margins: Style.space(2)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            source: root.activePlayer && root.activePlayer.trackArtUrl ? root.activePlayer.trackArtUrl : ""
            // mpd-mpris writes a zero-byte artwork file for streams without art,
            // so presence of a path is not proof of an image.
            visible: source !== "" && status === Image.Ready
          }

          Text {
            anchors.centerIn: parent
            visible: !artImage.visible
            text: "󰝚"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
          }
        }

        Column {
          spacing: Style.space(2)
          width: parent.width - Style.space(58)

          Text {
            textFormat: Text.PlainText
            text: root.title || "Nothing playing"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            textFormat: Text.PlainText
            text: root.artist
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }
        }
      }

      // ---- Transport ----
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)

        Button {
          iconText: "\uf048"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.activePlayer && root.activePlayer.canGoPrevious
          opacity: enabled ? 1.0 : 0.4
          onClicked: if (root.mediaService) root.mediaService.runAction("previous", false, root.mediaService.playerKey(root.activePlayer))
        }

        Button {
          iconText: root.isPlaying ? "\uf04c" : "\uf04b"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.panelGap
          verticalPadding: Style.spacing.controlPaddingY
          iconSize: Style.font.iconLarge
          enabled: root.activePlayer && (root.activePlayer.canTogglePlaying || root.activePlayer.canPlay || root.activePlayer.canPause)
          opacity: enabled ? 1.0 : 0.4
          onClicked: if (root.mediaService) root.mediaService.runAction("playPause", false, root.mediaService.playerKey(root.activePlayer))
        }

        Button {
          iconText: "\uf051"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.activePlayer && root.activePlayer.canGoNext
          opacity: enabled ? 1.0 : 0.4
          onClicked: if (root.mediaService) root.mediaService.runAction("next", false, root.mediaService.playerKey(root.activePlayer))
        }
      }

      Text {
        textFormat: Text.PlainText
        text: "No MPRIS player. Is mpd-mpris running?"
        visible: !root.activePlayer
        color: Qt.darker(root.bar.foreground, 1.6)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
      }

      // ---- Speakers ----
      PanelSeparator { foreground: root.bar.foreground }

      Column {
        id: speakerSection
        width: parent.width
        spacing: Style.space(6)

        Item {
          width: parent.width
          implicitHeight: Math.max(speakerHeader.implicitHeight, speakerPercent.implicitHeight)

          PanelSectionHeader {
            id: speakerHeader
            text: "SPEAKERS"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: speakerPercent
            textFormat: Text.PlainText
            text: root.activeOutput ? (Math.round(volumeSlider.dragging ? volumeSlider.liveValue : root.activeOutput.volume) + "%") : ""
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Item {
          width: parent.width
          height: Style.spacing.controlHeight
          visible: !!root.activeOutput

          PanelSlider {
            id: volumeSlider
            bar: root.bar
            anchors.fill: parent
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            minimum: 0
            maximum: 100
            step: 5
            integer: true
            value: root.activeOutput ? root.activeOutput.volume : 0
            enabled: !!root.activeOutput
            onMoved: function(v) { if (root.activeOutput) root.setOutputVolume(root.activeOutput.id, v) }
          }
        }

        Text {
          textFormat: Text.PlainText
          text: root.owntoneReachable ? "No speakers found." : ("OwnTone not reachable at " + root.owntoneApi)
          visible: root.outputs.length === 0
          color: Qt.darker(root.bar.foreground, 1.6)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          width: parent.width
        }

        Repeater {
          model: root.outputs

          CursorSurface {
            id: speakerRow
            required property var modelData
            readonly property bool isActive: modelData && modelData.selected === true
            // OwnTone answers 400 for these until paired, so the row would
            // otherwise look like a dead click.
            readonly property bool needsPin: modelData && modelData.needs_auth_key === true

            width: speakerSection.width
            current: isActive
            foreground: root.bar.foreground
            fill: root.hoverFill
            currentFill: root.selectedFill
            implicitHeight: speakerInner.implicitHeight + Style.spacing.xl

            Row {
              id: speakerInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: speakerRow.needsPin ? "\uf023" : (speakerRow.isActive ? "\uf028" : "\uf026")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                width: Style.space(22)
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: speakerRow.modelData ? String(speakerRow.modelData.name || "Speaker") : "Speaker"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: speakerRow.isActive
                elide: Text.ElideRight
                width: parent.width - Style.space(30)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (speakerRow.modelData)
                root.setOutputSelected(speakerRow.modelData.id, !speakerRow.isActive)
            }
          }
        }
      }

        Row {
          width: parent.width
          spacing: Style.space(6)
          visible: !!root.pendingAuthOutput

          TextField {
            id: pinField
            width: parent.width - Style.space(40)
            placeholderText: root.pendingAuthOutput
              ? ("PIN for " + root.pendingAuthOutput.name) : "PIN"
            foreground: root.bar.foreground
            font.family: root.bar.fontFamily
            anchors.verticalCenter: parent.verticalCenter
            inputMethodHints: Qt.ImhDigitsOnly
            onAccepted: {
              if (root.pendingAuthOutput) root.verifyOutput(root.pendingAuthOutput.id, text)
              text = ""
            }
          }

          Button {
            iconText: "\uf00c"
            foreground: root.bar.foreground
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            anchors.verticalCenter: parent.verticalCenter
            enabled: pinField.text.trim() !== ""
            opacity: enabled ? 1.0 : 0.4
            onClicked: {
              if (root.pendingAuthOutput) root.verifyOutput(root.pendingAuthOutput.id, pinField.text)
              pinField.text = ""
            }
          }
        }

      // ---- Stations ----
      PanelSeparator { foreground: root.bar.foreground }

      Column {
        id: stationSection
        width: parent.width
        spacing: Style.space(6)

        PanelSectionHeader {
          text: "STATIONS"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        Text {
          textFormat: Text.PlainText
          text: !root.owntoneReachable ? ("OwnTone not reachable at " + root.owntoneApi)
            : root.stationPlaylistId < 0 ? ("No playlist named \u201c" + root.stationsPlaylistName + "\u201d.")
            : "No stations yet. Add a stream URL below."
          visible: root.stations.length === 0
          color: Qt.darker(root.bar.foreground, 1.6)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          width: parent.width
        }

        Repeater {
          model: root.stations

          CursorSurface {
            id: stationRow
            required property var modelData
            // SomaFM titles are "Name: long blurb"; the name alone fits the card.
            readonly property string label: modelData
              ? String(modelData.title || "Station").split(":")[0]
              : "Station"
            readonly property bool isActive: modelData
              && root.nowPlayingTrackId !== -1
              && modelData.id === root.nowPlayingTrackId

            width: stationSection.width
            current: isActive
            foreground: root.bar.foreground
            fill: root.hoverFill
            currentFill: root.selectedFill
            implicitHeight: stationInner.implicitHeight + Style.spacing.xl

            Row {
              id: stationInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: stationRow.isActive && root.isPlaying ? "\uf04c" : "\uf04b"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                width: Style.space(22)
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: stationRow.label
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: stationRow.isActive
                elide: Text.ElideRight
                width: parent.width - Style.space(64)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (stationRow.modelData) root.playStation(stationRow.modelData.id)
            }

            // Declared after the row's MouseArea so it sits on top and the
            // click removes rather than starting playback.
            Button {
              iconText: "\uf1f8"
              foreground: root.bar.foreground
              tooltipText: "Remove station"
              horizontalPadding: Style.space(4)
              verticalPadding: Style.space(2)
              iconSize: Style.font.bodySmall
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              onClicked: if (stationRow.modelData)
                root.removeStation(stationRow.modelData.id, stationRow.modelData.path)
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          TextField {
            id: urlField
            width: parent.width - Style.space(40)
            placeholderText: "Stream URL"
            foreground: root.bar.foreground
            font.family: root.bar.fontFamily
            anchors.verticalCenter: parent.verticalCenter
            onAccepted: { root.addStation(text); text = "" }
          }

          Button {
            iconText: "\uf067"
            foreground: root.bar.foreground
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            anchors.verticalCenter: parent.verticalCenter
            enabled: urlField.text.trim() !== ""
            opacity: enabled ? 1.0 : 0.4
            onClicked: { root.addStation(urlField.text); urlField.text = "" }
          }
        }
      }

      // ---- Players ----
      PanelSeparator {
        visible: root.sourcePlayers.length > 0
        foreground: root.bar.foreground
      }

      Column {
        id: playerList
        visible: root.sourcePlayers.length > 0
        width: parent.width
        spacing: Style.space(6)

        PanelSectionHeader {
          text: "PLAYING FROM"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        Repeater {
          model: root.sourcePlayers

          CursorSurface {
            id: playerRow
            required property var modelData
            readonly property var player: modelData
            readonly property bool isActive: root.activePlayer && player
              && root.mediaService.playerKey(root.activePlayer) === root.mediaService.playerKey(player)
            readonly property string label: player
              ? (player.identity || player.desktopEntry || player.trackTitle || "Media source")
              : "Media source"

            width: playerList.width
            current: isActive
            foreground: root.bar.foreground
            fill: root.hoverFill
            currentFill: root.selectedFill
            implicitHeight: playerInner.implicitHeight + Style.spacing.xl

            Row {
              id: playerInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: playerRow.player && playerRow.player.isPlaying ? "\uf04c" : "\uf04b"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                width: Style.space(22)
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: playerRow.label
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: playerRow.isActive
                elide: Text.ElideRight
                width: parent.width - Style.space(30)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.mediaService) root.mediaService.selectPlayer(root.mediaService.playerKey(playerRow.player))
            }
          }
        }
      }
    }
  }
}

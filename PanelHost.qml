import QtQuick
import qs.Commons

// Embeds another plugin's own detail panel inside this overview.
//
// A first-party panel is a `qs.Ui.Panel` whose visible surface is a
// KeyboardPanel, and that is a popup window built to anchor to a bar slot. It
// will not paint over a fullscreen layer surface, which is where this overview
// lives. The way around it is to never let the window open: hold the popup's
// own `open` at false, set the panel controller open anyway so its timers and
// fetches behave as if it were on screen, then reparent the content out of the
// popup's `contentItem` into an Item of ours.
//
// The technique is OmaDash's (github.com/djmenig/OmaDash), which worked it out
// first; this is a smaller implementation of the same idea.
Item {
  id: root

  property string pluginId: ""
  property var bar: null
  property var pluginRegistry: null

  // Own-property lookup only: an id such as "__proto__" must not resolve to
  // something inherited from Object.
  readonly property var manifest: {
    var installedPlugins = pluginRegistry ? pluginRegistry.installedPlugins : null
    if (!installedPlugins || typeof installedPlugins !== "object")
      return null
    if (!Object.prototype.hasOwnProperty.call(installedPlugins, pluginId))
      return null
    var found = installedPlugins[pluginId]
    return found && typeof found === "object" ? found : null
  }
  readonly property bool installed: manifest !== null

  // `entryPoints.panel` when the plugin declares one. A bar-widget plugin
  // keeps its panel as an undeclared sibling file, which is why the fallback
  // is the conventional name rather than a manifest lookup.
  //
  // The registry has already validated declared entry points, but the file
  // loaded here is chosen by this plugin, so the same rule is applied again:
  // a relative path with no `..`, resolving inside the plugin's own folder.
  readonly property string panelPath: {
    if (!installed)
      return ""

    var dir = String(manifest.__sourceDir || "").replace(/\/$/, "")
    if (dir === "" || dir.indexOf("/") !== 0)
      return ""

    var entries = manifest.entryPoints && typeof manifest.entryPoints === "object"
      ? manifest.entryPoints : ({})
    var relative = typeof entries.panel === "string" && entries.panel !== ""
      ? entries.panel : "Panel.qml"
    if (relative.length > 256 || relative.indexOf("/") === 0
        || relative.indexOf("..") !== -1 || relative.indexOf("\n") !== -1)
      return ""

    var resolved = dir + "/" + relative
    if (resolved.indexOf(dir + "/") !== 0)
      return ""

    return Util.fileUrl(resolved)
  }

  property var popup: null
  property bool adopted: false
  // What the adopted content actually wants vertically. Panels stream their
  // content in (a network list, a forecast), so this is re-read after the
  // layout settles rather than trusted on the first frame.
  property real contentHeight: 0

  // A panel taller than its card is drawn at full size and then scaled down to
  // fit, rather than clipped or left to scroll. Below this the text stops being
  // worth reading, and clipping is the better failure.
  property real minScale: 0.62
  property real fitScale: 1
  // Set when the panel turns out not to be embeddable, so the caller can drop
  // the card rather than leave an empty one.
  property bool unembeddable: false
  property int adoptAttempts: 0
  readonly property int maxAdoptAttempts: 40

  // The popup surface among the panel's children. It is the child that carries
  // PopupCard's sizing helpers.
  function findPopup(panel) {
    var children = panel.data
    for (var i = 0; i < children.length; i++) {
      var child = children[i]
      if (child && (child.fittedContentWidth !== undefined || child.anchorItem !== undefined))
        return child
    }

    return null
  }

  function adopt(panel) {
    var surface = findPopup(panel)
    if (!surface) {
      // Content can take a few frames to exist. A panel that never surfaces
      // one is not embeddable, so give up rather than poll forever.
      if (root.adoptAttempts++ > root.maxAdoptAttempts)
        root.unembeddable = true
      else
        Qt.callLater(function() { root.adopt(panel) })
      return
    }

    root.popup = surface

    // Break the binding to the panel's own open state before opening the
    // controller, or the window flashes on screen for a frame.
    surface.open = false
    if (panel.controller)
      panel.controller.open = true
    if (panel.refresh)
      panel.refresh(true)

    // The surface is found; takeContent() gets its own full deadline.
    root.adoptAttempts = 0
    takeContent(surface)
  }

  function takeContent(surface) {
    if (root.adopted)
      return

    // Same deadline as adopt(): a surface whose content never arrives is
    // given up on rather than polled for the life of the overview.
    if (root.adoptAttempts++ > root.maxAdoptAttempts) {
      root.unembeddable = true
      return
    }

    var content = surface.contentItem
    if (!content || content.length === 0) {
      Qt.callLater(function() { root.takeContent(surface) })
      return
    }

    var wanted = []
    for (var i = 0; i < content.length; i++) {
      var item = content[i]
      if (!item)
        continue

      // The real content sits inside the key catcher rather than beside it,
      // and the catcher itself is only useful to a focused popup.
      if (String(item.toString()).indexOf("PanelKeyCatcher") >= 0) {
        var inner = item.children || []
        for (var j = 0; j < inner.length; j++)
          if (inner[j])
            wanted.push(inner[j])
      } else {
        wanted.push(item)
      }
    }

    if (wanted.length === 0) {
      Qt.callLater(function() { root.takeContent(surface) })
      return
    }

    // `anchors.fill: parent` re-resolves on reparent, so content written to
    // fill the popup fills this host instead.
    for (var k = 0; k < wanted.length; k++) {
      wanted[k].parent = hostArea
      wanted[k].visible = true
    }

    root.adopted = true
    measure()
    Qt.callLater(root.measure)
  }

  function measure() {
    var children = hostArea.children
    var tallest = 0

    for (var i = 0; i < children.length; i++) {
      var child = children[i]
      if (!child)
        continue

      // Adopted content is usually a Flickable written to fill the popup, so
      // its own height is whatever we gave it and says nothing. `contentHeight`
      // is what it actually needs.
      var wants = (child.contentHeight !== undefined && child.contentHeight > 0)
        ? child.contentHeight
        : (child.implicitHeight || 0)

      tallest = Math.max(tallest, wants)
    }

    // Hysteresis. Scaling widens the host, which can re-wrap the panel's text
    // and change the height again; without a deadband the two chase each other.
    if (tallest > 0 && Math.abs(tallest - root.contentHeight) > 2)
      root.contentHeight = tallest

    if (root.contentHeight <= 0 || root.height <= 0)
      return

    var wanted = Math.min(1, Math.max(root.minScale, root.height / root.contentHeight))
    // Quantised for the same reason.
    wanted = Math.round(wanted * 50) / 50
    if (Math.abs(wanted - root.fitScale) > 0.005)
      root.fitScale = wanted
  }

  implicitHeight: contentHeight

  // The host is laid out at the size the panel wants and then scaled to the
  // card, so content shorter than the card is simply centred and content taller
  // than it shrinks to fit. Scaling the host rather than the adopted items
  // leaves their own `anchors.fill` alone.
  Item {
    id: hostArea

    anchors.centerIn: parent
    width: parent.width / root.fitScale
    height: root.contentHeight > 0 ? root.contentHeight : parent.height
    scale: root.fitScale
    transformOrigin: Item.Center
    clip: true

    Behavior on scale {
      NumberAnimation { duration: 120 }
    }
  }

  // A panel that keeps loading rows after the first layout pass would
  // otherwise be measured while still half empty.
  Timer {
    interval: 400
    repeat: true
    running: root.adopted
    triggeredOnStart: true
    onTriggered: root.measure()
  }

  Loader {
    id: panelLoader

    active: root.installed && root.panelPath !== "" && !root.unembeddable
    source: root.panelPath
    // Kept visible until the content moves: an invisible Loader leaves its
    // children with no effective size, and they never lay out.
    visible: !root.adopted
    width: root.width
    height: root.height

    onLoaded: {
      if (!item)
        return

      if ("bar" in item) item.bar = root.bar
      if ("settings" in item) item.settings = ({})
      // Two live copies of a panel would otherwise fight over the same IPC
      // target, since the bar already has one mounted.
      if ("manageIpc" in item) item.manageIpc = false

      root.adoptAttempts = 0
      Qt.callLater(function() { root.adopt(item) })
    }
  }
}

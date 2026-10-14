package app.scenova.scenova

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter UI and receives the Android text-selection action.
 *
 * Scenova registers for `ACTION_PROCESS_TEXT`, so a reader who selects a word in
 * a reading app sees a Scenova entry in the system selection menu. Choosing it
 * delivers only the selected text; nothing else from the reading page is read or
 * forwarded. The text is handed to Dart over the capture channel, where the
 * entry gate trims it, enforces the six-word limit, and opens the clip view.
 *
 * The action presents the clip in place, over the reading app, rather than
 * opening the app: the window is transparent for this entry so the reading page
 * shows behind the card, and Dart works out which surface to show from
 * [METHOD_ENTRY_POINT]. Dismissing the card closes the activity ([METHOD_DISMISS])
 * so the reader returns to their page with nothing of Scenova left behind.
 *
 * `launchMode="singleTop"` means a second selection while the clip view is open
 * arrives through [onNewIntent] rather than starting a second task, so the open
 * view is updated in place.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingSelection: String? = null

    /**
     * Whether this instance was built as the in-place action surface, i.e. its
     * window is transparent. A later selection reaching an instance built over
     * the app has to rebuild it rather than show the card over the app.
     */
    private var actionWindow = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        actionWindow = isSelectionAction()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingSelection = selectionFrom(intent)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    // Dart asks for a selection that arrived before the UI was up.
                    METHOD_PENDING_SELECTION -> {
                        val selection = pendingSelection
                        pendingSelection = null
                        result.success(selection)
                    }
                    // Dart is ready to receive selections.
                    METHOD_READY -> result.success(null)
                    // Dart asks which entry point launched this process.
                    METHOD_ENTRY_POINT -> result.success(
                        if (isSelectionAction()) ENTRY_POINT_SELECTION_ACTION
                        else ENTRY_POINT_APP
                    )
                    // Dart is done with the in-place clip view, so the reading
                    // app comes back.
                    METHOD_DISMISS -> {
                        result.success(null)
                        finish()
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val selection = selectionFrom(intent) ?: return
        if (isSelectionAction() && !actionWindow) {
            // The window was built over the app, so the card cannot sit over the
            // reading page; rebuild this instance as the action surface. Dart
            // reads the selection from the recreated instance's pending handoff.
            recreate()
            return
        }
        val current = channel
        if (current != null) {
            current.invokeMethod(METHOD_CAPTURE, mapOf("text" to selection))
        } else {
            pendingSelection = selection
        }
    }

    /**
     * A transparent window for the selection action, so the reading page stays
     * visible behind the clip card. Every other entry keeps the app's own
     * opaque window and launch surface.
     */
    override fun getBackgroundMode(): BackgroundMode =
        if (isSelectionAction()) BackgroundMode.transparent else super.getBackgroundMode()

    private fun isSelectionAction(): Boolean =
        intent?.action == Intent.ACTION_PROCESS_TEXT

    private fun selectionFrom(intent: Intent?): String? {
        if (intent == null || intent.action != Intent.ACTION_PROCESS_TEXT) return null
        return intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
    }

    companion object {
        private const val CHANNEL = "app.scenova/capture"
        private const val METHOD_CAPTURE = "capture"
        private const val METHOD_READY = "ready"
        private const val METHOD_PENDING_SELECTION = "pendingSelection"
        private const val METHOD_ENTRY_POINT = "entryPoint"
        private const val METHOD_DISMISS = "dismiss"
        private const val ENTRY_POINT_APP = "app"
        private const val ENTRY_POINT_SELECTION_ACTION = "selectionAction"
    }
}

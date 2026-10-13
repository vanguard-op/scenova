package app.scenova.scenova

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter UI and receives the Android text-selection action.
 *
 * Scenova registers for `ACTION_PROCESS_TEXT`, so a reader who selects a word in
 * a reading app sees a Scenova entry in the system selection menu. Choosing it
 * delivers only the selected text; nothing else from the reading page is read or
 * forwarded. The text is handed to Dart over the capture channel, where the
 * entry gate trims it, enforces the six-word limit, and opens the in-context
 * clip view.
 *
 * `launchMode="singleTop"` means a second selection while the clip view is open
 * arrives through [onNewIntent] rather than starting a second task, so the open
 * view is updated in place.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingSelection: String? = null

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
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val selection = selectionFrom(intent) ?: return
        val current = channel
        if (current != null) {
            current.invokeMethod(METHOD_CAPTURE, mapOf("text" to selection))
        } else {
            pendingSelection = selection
        }
    }

    private fun selectionFrom(intent: Intent?): String? {
        if (intent == null || intent.action != Intent.ACTION_PROCESS_TEXT) return null
        return intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
    }

    companion object {
        private const val CHANNEL = "app.scenova/capture"
        private const val METHOD_CAPTURE = "capture"
        private const val METHOD_READY = "ready"
        private const val METHOD_PENDING_SELECTION = "pendingSelection"
    }
}

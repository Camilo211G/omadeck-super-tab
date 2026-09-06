import Quickshell
import Quickshell.Io
import QtQuick

// One helper run, published only if the run earned it.
//
// Every helper this plugin spawns goes through this: a fixed absolute
// executable, a hard deadline (GNU timeout signals the child's own process
// group, TERM then KILL), a byte ceiling enforced and counted at the producer,
// and a cleared environment rebuilt with only what the scripts need.
//
// The ceiling is counted in raw bytes at the producer rather than in the
// collected string. A QML string holds UTF-16 code units, so comparing its
// length with a byte ceiling under-counts multibyte data and can make
// truncated output look acceptable; and a byte-truncated tail is not valid
// UTF-8 anyway, so the decoded length cannot be trusted to reconstruct it.
// head caps the stream at maxBytes + 1 bytes before anything reaches this
// process and kills an unbounded writer with SIGPIPE at the source, tee copies
// those bytes to the real stdout (fd 4) while wc counts them, and a count above
// the ceiling exits overflowExit so the run is discarded whole.
//
// A run is consumable only when it ended on its own terms and stayed under the
// ceiling. Anything else -- a non-zero exit, a crash, a deadline kill, an
// overflow -- fails closed: `ready` is not emitted, and the caller keeps its
// last good reading instead of showing a truncated or absent one.
//
// The collector's streamFinished and the process's exited arrive in no
// guaranteed order, so each half records what it knows and whichever lands
// second does the publishing.
Item {
    id: root

    // Absolute path of the executable to run. Empty means there is nothing to
    // run yet, and start() does nothing.
    property string executable: ""
    // Deadline in seconds for the whole run, including the producer.
    property int seconds: 15
    // Raw byte ceiling on the producer's output.
    property int maxBytes: 256
    // Character ceiling on the decoded text handed to `ready`.
    property int maxChars: 256
    // The environment the helper runs with; the caller owns its contents.
    property var environment: ({})

    // A completed, usable run. Not emitted for a run that failed or overflowed.
    signal ready(string text)

    readonly property bool running: helper.running

    // The exit status a bounded producer uses to report that it had more to say
    // than the ceiling allows. Chosen above the range a helper of this plugin
    // returns on its own and below the shell's signal range.
    readonly property int overflowExit: 9

    function start() {
        if (root.executable === "")
            return;
        if (helper.running)
            return;
        helper.collected = "";
        helper.collectedReady = false;
        helper.judged = false;
        helper.usable = false;
        helper.running = true;
    }

    function stop() {
        helper.running = false;
    }

    Process {
        id: helper

        // What the collector decoded, held until the run has a verdict.
        property string collected: ""
        property bool collectedReady: false
        // Whether the run has exited, and whether that exit permits consuming
        // the output.
        property bool judged: false
        property bool usable: false

        command: ["/usr/bin/timeout", "--kill-after=2", String(root.seconds), "/bin/bash", "-c",
            // pipefail is what lets the producer's own verdict survive the
            // pipeline: without it the status would always be wc's, and a
            // missing executable or a producer that gave up halfway would look
            // like a clean run that simply had nothing to say.
            'set -o pipefail\n'
            + 'exec 4>&1\n'
            + 'n=$({ "$1"; } | /usr/bin/head -c "$(($2 + 1))" | /usr/bin/tee /dev/fd/4 | /usr/bin/wc -c)\n'
            + 'rc=$?\n'
            + 'n=${n//[^0-9]/}\n'
            + '[ -n "$n" ] || exit ' + root.overflowExit + '\n'
            // The ceiling has the first say. Above it the producer has been cut
            // off by head and its status is a SIGPIPE that says nothing about
            // whether it succeeded, so the overflow is reported instead.
            + '[ "$n" -gt "$2" ] && exit ' + root.overflowExit + '\n'
            + 'exit "$rc"\n',
            "omadeck-helper", root.executable, String(root.maxBytes)]
        clearEnvironment: true
        environment: root.environment

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var s = String(text);
                helper.collected = (s.length > root.maxChars ? s.slice(0, root.maxChars) : s).trim();
                helper.collectedReady = true;
                helper.publish();
            }
        }

        onExited: function (exitCode, exitStatus) {
            helper.usable = exitCode === 0 && exitStatus === 0;
            helper.judged = true;
            helper.publish();
        }

        function publish() {
            if (!helper.collectedReady || !helper.judged)
                return;
            if (helper.usable)
                root.ready(helper.collected);
            helper.collected = "";
        }
    }
}

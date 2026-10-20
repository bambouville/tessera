package net.schmizz.sshj.connection.channel;

import java.io.IOException;
import net.schmizz.sshj.connection.channel.direct.Session;
import net.schmizz.sshj.connection.channel.direct.Signal;

/**
 * Uses SSHJ 0.40's channel lock to order TERM before the CLOSE handshake.
 * An isOpen() check followed by signal() is racy: the reader can acknowledge
 * peer CLOSE in between, sending the signal to an already retired channel.
 * Package placement grants access to the same guard SSHJ uses for writes.
 */
public final class TesseraChannelCancellation {
    private TesseraChannelCancellation() {}

    public static void terminate(Session.Command command, boolean force) throws IOException {
        ((AbstractChannel) command).whileOpen(() -> command.signal(force ? Signal.KILL : Signal.TERM));
    }
}

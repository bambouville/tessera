package com.termux.terminal;

/**
 * Text-presentation twins for the media-control symbols a monospace terminal
 * face is entitled to be missing.
 * <p/>
 * U+23F4..U+23FA are {@code Emoji=Yes, Emoji_Presentation=No}: a terminal must
 * draw them as <em>text</em> — one cell wide, in the pen colour — exactly as it
 * draws {@code ✓} or {@code ●}. The bundled JetBrains Mono face has no glyph
 * for any of them, so Android resolves them through the system fallback chain,
 * where one of two things goes wrong:
 * <ul>
 * <li>the colour emoji face claims the code point (U+23FA renders as the blue
 * "record button" tile), and because that glyph advances about two cells while
 * {@link WcWidth} reserves one, {@link com.termux.view.TerminalRenderer}
 * squeezes it horizontally into half a cell;</li>
 * <li>or no installed face covers it at all (U+23F5 on Pixel) and the row shows
 * .notdef boxes.</li>
 * </ul>
 * iOS fixed the same defect for its terminal in commit 8031a27 ("Prefer text
 * glyphs for terminal symbol fallback") by putting text faces ahead of the
 * colour emoji face in the font cascade. Android exposes no per-Typeface
 * cascade list, so the equivalent decision is taken here: the renderer draws
 * each of these as its Geometric-Shapes text twin, which the bundled face does
 * carry at exactly one cell.
 * <p/>
 * The substitution is a <em>rendering</em> decision only. The emulator keeps
 * the code point the host sent, so selection, copy, and the Agent Centre
 * snapshot parsers still see the original character.
 */
public final class TextPresentation {

    /** First candidate code point; the table is indexed from here. */
    public static final char FIRST = '⏴';
    /** Last candidate code point. */
    public static final char LAST = '⏺';

    private static final char[] SUBSTITUTES = {
        '◀', // U+23F4 BLACK MEDIUM LEFT-POINTING TRIANGLE  -> BLACK LEFT-POINTING TRIANGLE
        '▶', // U+23F5 BLACK MEDIUM RIGHT-POINTING TRIANGLE -> BLACK RIGHT-POINTING TRIANGLE
        '▲', // U+23F6 BLACK MEDIUM UP-POINTING TRIANGLE    -> BLACK UP-POINTING TRIANGLE
        '▼', // U+23F7 BLACK MEDIUM DOWN-POINTING TRIANGLE  -> BLACK DOWN-POINTING TRIANGLE
        '‖', // U+23F8 DOUBLE VERTICAL BAR (pause)          -> DOUBLE VERTICAL LINE
        '■', // U+23F9 BLACK SQUARE FOR STOP                -> BLACK SQUARE
        '●', // U+23FA BLACK CIRCLE FOR RECORD              -> BLACK CIRCLE
    };

    private TextPresentation() {
    }

    /** Number of candidates in the table. */
    public static int count() {
        return SUBSTITUTES.length;
    }

    /** The code point a host may send for candidate {@code index}. */
    public static char source(int index) {
        return (char) (FIRST + index);
    }

    /** The text-presentation twin for candidate {@code index}. */
    public static char substitute(int index) {
        return SUBSTITUTES[index];
    }

    /** Table index for {@code c}, or {@code -1} when it is not a candidate. */
    public static int indexOf(char c) {
        return (c < FIRST || c > LAST) ? -1 : (c - FIRST);
    }
}

# Terminal input vectors v1

These vectors freeze the platform-neutral mapping from normalized modifiers,
terminal keys, software-keyboard bytes, and mouse events to terminal wire bytes.
UIKit/AppKit/Android event conversion and IME composition remain platform-owned.

Hex strings contain the exact bytes written to the terminal transport. Command
is present in one modifier case to prove that it never enters terminal wire
encoding.

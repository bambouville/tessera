# JNI entry points are resolved by their Java names from tessera_core_jni.cpp.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# The native callbacks resolve these methods by their stable JVM name/signature.
-keep class com.bambouville.tessera.core.bridge.NativeEventSink {
    void onEvent(java.nio.ByteBuffer);
}
-keep class com.bambouville.tessera.core.bridge.NativeAgentEventSink {
    void onEvent(java.nio.ByteBuffer);
}

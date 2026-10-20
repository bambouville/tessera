# JNI entry points are resolved by their Java names from tessera_core_jni.cpp.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# The native callback resolves this method by its stable JVM name/signature.
-keep class com.bambouville.tessera.core.bridge.NativeEventSink {
    void onEvent(java.nio.ByteBuffer);
}

# The google_mlkit_text_recognition plugin can construct a recogniser for any
# script — Latin, Chinese, Devanagari, Japanese or Korean — and references all
# five option classes from one method. Only the Latin recogniser is depended
# on here, so R8 finds three of those references unresolvable and fails the
# release build outright. Debug builds do not run R8, so this never appears
# until a release build is attempted.
#
# Silencing the warning is correct rather than a workaround: the classes are
# genuinely absent, the code path that would touch them is never taken, and
# pulling in three unused recognition models would add tens of megabytes to
# the APK for scripts the app does not offer.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# ML Kit loads its detectors reflectively through Play Services, so the
# entry points must survive shrinking.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }

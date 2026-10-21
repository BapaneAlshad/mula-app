# JNI looks up these Kotlin classes and method parameter types by their names.
# Keep them while retaining R8 shrinking and optimization for the application.
# https://github.com/flutter/flutter/issues/194649
# https://github.com/flutter/packages/pull/13311
-keep class kotlin.Unit { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.coroutines.Continuation { *; }
-keep class kotlin.coroutines.intrinsics.CoroutineSingletons { *; }
-keep class kotlin.coroutines.intrinsics.IntrinsicsKt { *; }

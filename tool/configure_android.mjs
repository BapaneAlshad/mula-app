// Apply MULA's native requirements after Flutter generates the Android engine.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function configureGradle(source, kotlin) {
  let result = source;
  const java17Target = (match) => match.includes('JvmTarget.')
    ? match.replace(/JVM_[A-Z0-9_]+/, 'JVM_17')
    : 'jvmTarget = "17"';
  const required = (expression, replacement, label) => {
    if (!expression.test(result)) {
      throw new Error(`Flutter Android template changed: ${label} not found.`);
    }
    result = result.replace(expression, replacement);
  };

  if (kotlin) {
    required(/^([ \t]*)compileSdk\s*=.*$/m,
      '$1compileSdk = maxOf(36, flutter.compileSdkVersion)', 'compileSdk');
    required(/^([ \t]*)minSdk\s*=.*$/m,
      '$1minSdk = maxOf(24, flutter.minSdkVersion)', 'minSdk');
    required(/compileOptions\s*\{/,
      'compileOptions {\n        isCoreLibraryDesugaringEnabled = true',
      'compileOptions');
    required(/sourceCompatibility\s*=\s*JavaVersion\.VERSION_[A-Z0-9_]+/,
      'sourceCompatibility = JavaVersion.VERSION_17', 'Java sourceCompatibility');
    required(/targetCompatibility\s*=\s*JavaVersion\.VERSION_[A-Z0-9_]+/,
      'targetCompatibility = JavaVersion.VERSION_17', 'Java targetCompatibility');
    required(/\brelease\s*\{/,
      'release {\n' +
      '            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")',
      'release build type');
    result = result.replace(/jvmTarget\s*=\s*[^\n}]+/g, java17Target);
    result += '\n// Required by scheduled notifications and local authentication.\n' +
      'dependencies {\n' +
      '    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n' +
      '    implementation("androidx.appcompat:appcompat:1.7.1")\n' +
      '}\n';
  } else {
    required(/^([ \t]*)compileSdk(?:Version)?\s*(?:=\s*)?.*$/m,
      '$1compileSdk Math.max(36, flutter.compileSdkVersion)', 'compileSdk');
    required(/^([ \t]*)minSdk(?:Version)?\s*(?:=\s*)?.*$/m,
      '$1minSdk Math.max(24, flutter.minSdkVersion)', 'minSdk');
    required(/compileOptions\s*\{/,
      'compileOptions {\n        coreLibraryDesugaringEnabled true',
      'compileOptions');
    required(/sourceCompatibility\s*(?:=\s*)?JavaVersion\.VERSION_[A-Z0-9_]+/,
      'sourceCompatibility JavaVersion.VERSION_17', 'Java sourceCompatibility');
    required(/targetCompatibility\s*(?:=\s*)?JavaVersion\.VERSION_[A-Z0-9_]+/,
      'targetCompatibility JavaVersion.VERSION_17', 'Java targetCompatibility');
    required(/\brelease\s*\{/,
      'release {\n' +
      '            proguardFiles getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro"',
      'release build type');
    result = result.replace(/jvmTarget\s*=\s*[^\n}]+/g, java17Target);
    result += '\n// Required by scheduled notifications and local authentication.\n' +
      'dependencies {\n' +
      '    coreLibraryDesugaring "com.android.tools:desugar_jdk_libs:2.1.4"\n' +
      '    implementation "androidx.appcompat:appcompat:1.7.1"\n' +
      '}\n';
  }
  return result.replace(/^\s*\/\/ TODO:.*\r?\n/gm, '');
}

export function configureAndroid(root = process.cwd()) {
  const kotlinFile = path.join(root, 'android/app/build.gradle.kts');
  const groovyFile = path.join(root, 'android/app/build.gradle');
  const kotlin = fs.existsSync(kotlinFile);
  const file = kotlin ? kotlinFile : groovyFile;
  if (!fs.existsSync(file)) {
    throw new Error('Run flutter create in GitHub Actions before native configuration.');
  }
  if (!fs.existsSync(path.join(root, 'android/app/proguard-rules.pro'))) {
    throw new Error('Restore MULA android/app/proguard-rules.pro before native configuration.');
  }
  const source = fs.readFileSync(file, 'utf8');
  if (source.includes('com.android.tools:desugar_jdk_libs:2.1.4')) {
    throw new Error('Android engine is already configured. Generate it once per build.');
  }
  fs.writeFileSync(file, configureGradle(source, kotlin));

  // flutter create also generates a counter test unrelated to MULA's real tests.
  const sampleTest = path.join(root, 'test/widget_test.dart');
  if (fs.existsSync(sampleTest)) {
    const sample = fs.readFileSync(sampleTest, 'utf8');
    if (sample.includes('Counter increments smoke test') && sample.includes('MyApp')) {
      fs.unlinkSync(sampleTest);
    }
  }
  process.stdout.write('Android configured: SDK >=36, minSdk >=24, Java 17, desugaring, AppCompat, JNI R8 keep rules.\n');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  configureAndroid();
}

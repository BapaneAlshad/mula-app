import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { configureAndroid, configureGradle } from './configure_android.mjs';

const repositoryRoot = fileURLToPath(new URL('../', import.meta.url));
const keepRules = fs.readFileSync(
  path.join(repositoryRoot, 'android/app/proguard-rules.pro'), 'utf8');

const kotlinTemplate = `
plugins { id("com.android.application") }
android {
    compileSdk = flutter.compileSdkVersion
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions { jvmTarget = JavaVersion.VERSION_11.toString() }
    defaultConfig {
        minSdk = flutter.minSdkVersion
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}
`;

const groovyTemplate = `
plugins { id 'com.android.application' }
android {
    compileSdk flutter.compileSdkVersion
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_11
        targetCompatibility JavaVersion.VERSION_11
    }
    kotlinOptions { jvmTarget = "11" }
    defaultConfig {
        minSdkVersion flutter.minSdkVersion
    }
    buildTypes {
        release {
            signingConfig signingConfigs.debug
        }
    }
}
`;

for (const [language, template, kotlin] of [
  ['Kotlin', kotlinTemplate, true],
  ['Groovy', groovyTemplate, false],
]) {
  test(`${language} generated release build applies optimized and JNI keep rules`, () => {
    const configured = configureGradle(template, kotlin);
    const release = configured.match(/\brelease\s*\{([^}]+)\}/)?.[1];
    assert.ok(release, 'release block must exist');
    assert.match(release,
      /proguardFiles\(?\s*getDefaultProguardFile\("proguard-android-optimize\.txt"\), "proguard-rules\.pro"\)?/);
    assert.match(release, /signingConfig/);
    assert.match(release, /mulaRelease/);
    assert.match(configured, /key\.properties/);
    assert.match(configured, /PKCS12/);
    assert.ok(configured.indexOf('plugins') < configured.indexOf('mulaSigningProperties'));
    assert.doesNotMatch(configured, /(?:isMinifyEnabled|minifyEnabled)\s*(?:=\s*)?false/);
    assert.doesNotMatch(configured, /dontoptimize|dontobfuscate|dontshrink/);
  });

  test(`${language} Android generation preserves restored custom JNI rules`, (context) => {
    const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'mula-android-'));
    context.after(() => fs.rmSync(fixtureRoot, { recursive: true, force: true }));
    const appDirectory = path.join(fixtureRoot, 'android/app');
    fs.mkdirSync(appDirectory, { recursive: true });
    const gradleFile = path.join(appDirectory, kotlin ? 'build.gradle.kts' : 'build.gradle');
    const rulesFile = path.join(appDirectory, 'proguard-rules.pro');
    fs.writeFileSync(gradleFile, template);
    fs.writeFileSync(rulesFile, keepRules);

    configureAndroid(fixtureRoot);

    assert.match(fs.readFileSync(gradleFile, 'utf8'), /proguard-rules\.pro/);
    assert.equal(fs.readFileSync(rulesFile, 'utf8'), keepRules);
  });
}

test('JNI rules preserve all six Kotlin types used by name without disabling R8', () => {
  const keptTypes = [...keepRules.matchAll(/^-keep class ([^ ]+) \{ \*; \}$/gm)]
    .map((match) => match[1]);
  assert.deepEqual(keptTypes.sort(), [
    'kotlin.Unit',
    'kotlin.Result',
    'kotlin.Result$Failure',
    'kotlin.coroutines.Continuation',
    'kotlin.coroutines.intrinsics.CoroutineSingletons',
    'kotlin.coroutines.intrinsics.IntrinsicsKt',
  ].sort());
  assert.doesNotMatch(keepRules, /^-dont(?:optimize|obfuscate|shrink)/m);
});

test('Android generation fails early if cloud restoration loses custom JNI rules', (context) => {
  const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'mula-android-'));
  context.after(() => fs.rmSync(fixtureRoot, { recursive: true, force: true }));
  const appDirectory = path.join(fixtureRoot, 'android/app');
  fs.mkdirSync(appDirectory, { recursive: true });
  const gradleFile = path.join(appDirectory, 'build.gradle.kts');
  fs.writeFileSync(gradleFile, kotlinTemplate);

  assert.throws(() => configureAndroid(fixtureRoot), /Restore MULA.*proguard-rules\.pro/);
  assert.equal(fs.readFileSync(gradleFile, 'utf8'), kotlinTemplate);
});

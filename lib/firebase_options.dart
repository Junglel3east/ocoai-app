// Placeholder Firebase options — replace by running:
//   dart pub global activate flutterfire_cli
//   flutterfire configure
//
// Add android/app/google-services.json and ios GoogleService-Info.plist from Firebase Console.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      default:
        return android;
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: '1:000000000000:web:0000000000000000000000',
    messagingSenderId: '000000000000',
    projectId: 'on-chain-oracle-ai',
    authDomain: 'on-chain-oracle-ai.firebaseapp.com',
    storageBucket: 'on-chain-oracle-ai.appspot.com',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: '1:000000000000:android:0000000000000000000000',
    messagingSenderId: '000000000000',
    projectId: 'on-chain-oracle-ai',
    storageBucket: 'on-chain-oracle-ai.appspot.com',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: '1:000000000000:ios:0000000000000000000000',
    messagingSenderId: '000000000000',
    projectId: 'on-chain-oracle-ai',
    storageBucket: 'on-chain-oracle-ai.appspot.com',
    iosBundleId: 'com.onchainoracleai.app',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: '1:000000000000:ios:0000000000000000000000',
    messagingSenderId: '000000000000',
    projectId: 'on-chain-oracle-ai',
    storageBucket: 'on-chain-oracle-ai.appspot.com',
    iosBundleId: 'com.onchainoracleai.app',
  );
}

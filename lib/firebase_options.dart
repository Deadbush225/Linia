import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

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
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.linux:
        return linux;
      default:
        return web;
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyAzXfiCh0dFn3Sqw75If5uEFvzw8VoxCMY',
    appId: '1:106610450876:web:ed673fafd64b4c59dd4bb9',
    messagingSenderId: '106610450876',
    projectId: 'todo-76f15',
    authDomain: 'todo-76f15.firebaseapp.com',
    storageBucket: 'todo-76f15.firebasestorage.app',
    measurementId: 'G-X2QJ3QMZ3F',
  );

  // Reuses the available Firebase app id/config so the app can initialize

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyBEKM_L00sgPsdltkOmQVX74Jj1QPslfFQ',
    appId: '1:106610450876:android:5425ad7d15e77583dd4bb9',
    messagingSenderId: '106610450876',
    projectId: 'todo-76f15',
    storageBucket: 'todo-76f15.firebasestorage.app',
  );

  // without generated native configs in this repository snapshot.

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyADV1YzY4PscA70BRZ06wvQcj8VH4C8biw',
    appId: '1:106610450876:ios:26a93c2e26356fb6dd4bb9',
    messagingSenderId: '106610450876',
    projectId: 'todo-76f15',
    storageBucket: 'todo-76f15.firebasestorage.app',
    iosBundleId: 'com.example.ganttViewer',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyADV1YzY4PscA70BRZ06wvQcj8VH4C8biw',
    appId: '1:106610450876:ios:26a93c2e26356fb6dd4bb9',
    messagingSenderId: '106610450876',
    projectId: 'todo-76f15',
    storageBucket: 'todo-76f15.firebasestorage.app',
    iosBundleId: 'com.example.ganttViewer',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyAzXfiCh0dFn3Sqw75If5uEFvzw8VoxCMY',
    appId: '1:106610450876:web:c1685e318d3e04fcdd4bb9',
    messagingSenderId: '106610450876',
    projectId: 'todo-76f15',
    authDomain: 'todo-76f15.firebaseapp.com',
    storageBucket: 'todo-76f15.firebasestorage.app',
    measurementId: 'G-7EH37Q1KN1',
  );

  static const FirebaseOptions linux = FirebaseOptions(
    apiKey: 'AIzaSyAzXfiCh0dFn3Sqw75If5uEFvzw8VoxCMY',
    appId: '1:106610450876:web:f53421b6cc33ada5dd4bb9',
    messagingSenderId: '106610450876',
    projectId: 'todo-76f15',
    storageBucket: 'todo-76f15.firebasestorage.app',
  );
}
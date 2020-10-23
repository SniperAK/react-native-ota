package me.alexk.ota;

import com.facebook.react.ReactPackage;
import com.facebook.react.bridge.NativeModule;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.uimanager.ViewManager;

import java.lang.annotation.Native;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * Created by alex on 2018. 4. 3..
   */
public class OtaPackage implements ReactPackage {
  @Override
  public List<NativeModule> createNativeModules( ReactApplicationContext reactContext ) {
    return Arrays.<NativeModule>asList(
      new OtaModule( reactContext )
    );
  }

  @Override
  public List<ViewManager> createViewManagers( ReactApplicationContext reactContext ) {
    return Collections.emptyList();
  }
}
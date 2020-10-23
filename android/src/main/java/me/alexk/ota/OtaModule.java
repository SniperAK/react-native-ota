package me.alexk.ota;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.res.AssetManager;

import com.facebook.react.bridge.Callback;

import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;

import net.lingala.zip4j.core.ZipFile;
import net.lingala.zip4j.exception.ZipException;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.security.MessageDigest;
import java.util.HashMap;
import java.util.Map;

public class OtaModule extends ReactContextBaseJavaModule {
  private static final String JS_BUNDLE                 = "bundle/";
  private static final String JS_BUNDLE_ZIP_NAME        = "main.bundle";
  private static final String JS_BUNDLE_TEMP            = "__temp__";
  private static final String JS_BUNDLE_FILE            = JS_BUNDLE + "main.jsbundle";

  private static final String BUNDLE_URL_PARAMS         = "/index.bundle?platform=android";

  private static final String KEY_BUNDLE_DOWNLOAD_URL   = "bundle_download_url";
  private static final String KEY_USE_BUNDLE            = "use_bundle";
  private static final String KEY_USE_DOWNLOAD          = "use_download";
  private static final String KEY_BUNDLE_HASH           = "bundle_hash";
  private static final String KEY_APP_VERSION           = "bundle_app_version";

  private static boolean mIsDebug       = true;
  private static String mApplicationId  = null;
  private static String mDefaultServer  = null;
  private static String mPassPhase      = null;
  private static Boolean mUseBundle     = false;
  private static Boolean mUseDownload   = false;

  @SuppressLint("StaticFieldLeak")
  private static Context mContext = null;

  private static String getSharedPreferenceName(){
    return mApplicationId;
  }

  private static void saveSharedData( String k, Object d){
    SharedPreferences p = mContext.getSharedPreferences(getSharedPreferenceName(), Activity.MODE_PRIVATE);
    if(p == null || k == null || d == null) {
      return;
    }

    SharedPreferences.Editor e = p.edit();

    if(Boolean.class == d.getClass() ) {
      e.putBoolean(k, (Boolean)d);
    }
    if(String.class  == d.getClass() ) {
      e.putString(k, (String)d);
    }

    e.apply();
  }

  private static Object getSharedData( String k, Class<?> d, Object v){
    SharedPreferences p = mContext.getSharedPreferences(getSharedPreferenceName(), Activity.MODE_PRIVATE);

    return (p == null || k == null) ? v :
      (Boolean.class == d) ? p.getBoolean(k, (Boolean) v) :
      (String.class  == d) ? p.getString(k, (String) v) : v;
  }

  @SuppressLint("UseValueOf")
  private static boolean getBoolean( String strKey, Boolean defaultValue ){
    return (boolean) getSharedData( strKey, Boolean.class, defaultValue );
  }

  @SuppressLint("UseValueOf")
  private static String getString( String strKey, String defaultValue ){
    return (String) getSharedData( strKey, String.class, defaultValue );
  }

  OtaModule( ReactApplicationContext reactContext ) {
    super( reactContext );
//    mContext = reactContext;
  }

  private static String getAppVersion(){
    try {
      return mContext.getPackageManager().getPackageInfo(mContext.getPackageName(), 0).versionName;
    } catch(PackageManager.NameNotFoundException e) {
      return "Failed to acquire app version !";
    }
  }

  public static String getJsCodeLocation(){
    return useBundle() ? pathForLocalJSCodeLocation() : null;
  }

  public static void init( Context context, String appId, String defaultBundleServer, String passPhrase, boolean isDebug, boolean useBundle, boolean useDownload) {
    mContext        = context;
    mIsDebug        = isDebug;
    mApplicationId  = appId;
    mDefaultServer  = defaultBundleServer;
    mPassPhase      = passPhrase;
    mUseBundle      = useBundle;
    mUseDownload    = useDownload;

    if( !useBundle() ) {
      return;
    }

    String hash = getLastBundleHash();

    if( hash != null ) {
      unzip( internalPath( hash ), path(), false );
    }
    else {
      String oldHash    = getString( KEY_BUNDLE_HASH, "" );
      if( oldHash != null ) {
        File oldBundleFile = new File( internalPath( oldHash ));
        if( oldBundleFile.exists() ) {
          oldBundleFile.delete();
        }
      }

      hash = copyFromAssetFile( JS_BUNDLE + JS_BUNDLE_ZIP_NAME );
      unzip( internalPath( hash ), path(), true );
      setLastBundleHash( hash );
    }
  }


  private static String getLastBundleHash() {
    String hash    = getString( KEY_BUNDLE_HASH, "" );
    String stored  = getString( KEY_APP_VERSION, "" );
    String internalPath = internalPath( hash );
    File file = new File( internalPath );

    String lastHash = getAppVersion().equals( stored ) && file.exists() ? hash : null;

    return lastHash;
  }

  private static void setLastBundleHash( String hash ){
    saveSharedData( KEY_BUNDLE_HASH, hash );
    saveSharedData( KEY_APP_VERSION, getAppVersion() );
  }

  private static String hashToString(byte[] bytes) {
    StringBuilder r = new StringBuilder();
    for ( byte b : bytes ) {
      r.append( Integer.toString( ( b & 0xff ) + 0x100, 16 ).substring( 1 ) );
    }
    return r.toString();
  }

  private static String md5( String filePath ) {
    InputStream inputStream = null;
    try {
      inputStream = new FileInputStream(filePath);
      byte[] buffer = new byte[1024];
      MessageDigest digest = MessageDigest.getInstance("MD5");
      int read;
      while ((read = inputStream.read(buffer)) != -1) {
        digest.update(buffer, 0, read);
      }
      return hashToString(digest.digest());
    } catch (Exception e) {
      e.printStackTrace();
      return null;
    } finally {
      if (inputStream != null) {
        try {
          inputStream.close();
        } catch (Exception e ) {
          e.printStackTrace();
        }
      }
    }
  }

  private static String copyFromAssetFile( String assetPath ) {
    String tempPath = internalPath( JS_BUNDLE_TEMP );
    File temp = new File(tempPath);
    AssetManager manager = mContext.getAssets();
    InputStream is = null;
    try {
      is = manager.open( assetPath );
    } catch ( IOException e ) {
      e.printStackTrace();
    }
    if( is == null ) {
      return null;
    }

    String hash = null;
    OutputStream os = null;
    try {
      os = new FileOutputStream( temp );
      byte[] buffer = new byte[1024];
      int read;
      MessageDigest digest = MessageDigest.getInstance("MD5");

      while ((read = is.read(buffer)) != -1) {
        os.write(buffer, 0, read);
        digest.update(buffer, 0, read);
      }

      temp.renameTo( new File( internalPath( hash = hashToString( digest.digest() ) ) ) );

      is.close();
      os.flush();
      os.close();
    }
    catch (Exception e) {
      e.printStackTrace();
    }
    finally {
      if( os != null ) {
        try {
          os.close();
        } catch ( IOException e ) {
          e.printStackTrace();
        }
      }
      try {
        is.close();
      } catch (Exception e ) {
        e.printStackTrace();
      }
    }
    return hash;
  }

  private static String path() {
     return mContext.getFilesDir().getAbsolutePath();
  }

  private static String internalPath( String target ) {
    return path() + File.separator + target;
  }

  private static void unzip( String zipPath, final String destination, boolean isFull ){
    try {
      ZipFile zipFile = new ZipFile( zipPath );
      if( zipFile.isEncrypted() ) {
        zipFile.setPassword( mPassPhase );
      }
      if( isFull ) {
        zipFile.extractAll(destination);
      } else zipFile.extractFile(JS_BUNDLE_FILE, destination);

    } catch (ZipException e) {
      e.printStackTrace();
    }
  }

  private static String pathForLocalJSCodeLocation() {
    String path = internalPath( JS_BUNDLE_FILE );
    File file = new File( path );
    return file.exists() ? path : null;
  }

  private static boolean useBundle() {
    return getBoolean( KEY_USE_BUNDLE, mUseBundle );
  }

  private static boolean useDownload() {
    return getBoolean( KEY_USE_DOWNLOAD, mUseDownload );
  }

  /************************
   * React Native Methods *
   ************************/

  @Override
  public String getName() {
    return "Ota";
  }

  @Override
  public Map<String, Object> getConstants() {
    Map<String, Object> constants = new HashMap<>();
    constants.put( "passphrase", mPassPhase );
    constants.put( "useBundle", useBundle() );
    constants.put( "useDownload", useDownload() );
    constants.put( "hash", getLastBundleHash());
    constants.put( "path", path() );
    constants.put( "params", BUNDLE_URL_PARAMS + "&dev="+ mIsDebug + "&appId=" + mApplicationId + "&app_ver=" + getAppVersion() );
    return constants;
  }

  @ReactMethod
  public void reloadApp() {
    Intent restartIntent = mContext.getPackageManager().getLaunchIntentForPackage( mContext.getPackageName() );
    int pendingIntentId = 123456;
    PendingIntent pendingIntent = PendingIntent.getActivity( mContext, pendingIntentId, restartIntent, PendingIntent.FLAG_CANCEL_CURRENT );
    AlarmManager mgr = (AlarmManager) mContext.getSystemService( Context.ALARM_SERVICE );
    if( mgr != null ) {
      mgr.set( AlarmManager.RTC, System.currentTimeMillis() + 10, pendingIntent );
    }
    System.exit( 0 );
  }

  @ReactMethod
  public void getLastHash( Callback callback ) {
    callback.invoke( getLastBundleHash() );
  }

  @ReactMethod
  public void setLastHash( String hash, Callback callback ) {
    setLastBundleHash( hash );
    callback.invoke();
  }

  @ReactMethod
  public void getUseBundle( Callback callback ) {
    callback.invoke( useBundle() );
  }

  @ReactMethod
  public void setUseBundle( Boolean useBundle ) {
    saveSharedData( KEY_USE_BUNDLE, useBundle );
  }

  @ReactMethod
  public void getUseDownload( Callback callback ) {
    callback.invoke( useDownload() );
  }

  @ReactMethod
  public void setUseDownload( Boolean useDownload ) {
    saveSharedData( KEY_USE_DOWNLOAD, useDownload );
  }

  @ReactMethod
  public void getSavedBundleDownloadURL( Callback callback ){
    callback.invoke( getString( KEY_BUNDLE_DOWNLOAD_URL, mDefaultServer ) );
  }

  @ReactMethod
  public void setSavedBundleDownloadURL( String url ){
    saveSharedData( KEY_BUNDLE_DOWNLOAD_URL, url );
  }

  @ReactMethod
  public void unzip( final String zipPath, final String destination, final boolean isFull, final Promise promise) {
    try {
      ZipFile zipFile = new ZipFile( zipPath );
      if( zipFile.isEncrypted() ) {
        zipFile.setPassword( mPassPhase );
      }

      if( isFull ) {
        zipFile.extractAll( destination );
      } else zipFile.extractFile( JS_BUNDLE_FILE, destination);

      promise.resolve( null );
    } catch (ZipException e) {
      e.printStackTrace();
      promise.reject(null, "Failed to extract file " + e.getLocalizedMessage());
    }
  }

  @ReactMethod
  public void md5( String path, Callback callback ) {
    callback.invoke( OtaModule.md5( path ) );
  }
}

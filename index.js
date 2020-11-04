import {
  NativeModules,
} from 'react-native';

const { Ota } = NativeModules;

import fs from 'react-native-fs';
import RNFetchBlob from 'rn-fetch-blob'
import Crypto from 'crypto-js';
import EventEmitter from 'EventEmitter';

const DownloadStartEvent    = 'DownloadStartEvent';
const DownloadProgressEvent = 'DownloadProgressEvent';
const DownloadCompleteEvent = 'DownloadCompleteEvent';

const Events = {
  DownloadStartEvent,
  DownloadProgressEvent,
  DownloadCompleteEvent,
};

GLOBAL.reload = ()=>{
  Ota.reloadApp();
}
/**
1. check use bundle
2. check use download
3. check for update
  3.1. create hmac // done
  3.2. check hash to local hash
4. download if needed
5. unzip
  5.1.
6. reload
**/

class Bundler {
  constructor(){
    if( !Ota ) {
      console.error( 'Can`t find Ota in NativeModules, Make sure Ota in NativeModules.');
      return;
    }
    this._eventEmitter = new EventEmitter();
    this._eventListeners = new Map();
    this.Ota = Ota;

    this.DownloadStartEvent = DownloadStartEvent;
    this.DownloadProgressEvent = DownloadProgressEvent;
    this.DownloadCompleteEvent = DownloadCompleteEvent;

    this.synchronize().then(()=>this.removeJS());
  }

  synchronize(){
    return Promise.all([
      new Promise(r=>Ota.getLastHash(v=>r(this._lastHash=v))),
    ])
  }

  get paramsWithHmac() {
    let urlParams = Ota.params;
    let passphrase = Ota.passphrase;
    let t = Date.now();
    let hmac = Crypto.enc.Base64.stringify( Crypto.HmacSHA256( urlParams + '+' + t.toString(), passphrase + '+' + t.toString() ) ).replace('=','');
    let url = urlParams + '&hmac=' + hmac + '&t=' + t;
    return url;
  }

  get lastHash(){
    return this._lastHash;
  }

  setLastHash( hash ) {
    return new Promise(r=>Ota.setLastHash( hash, r ))
  }
  
  set bundleDownloadURL( url ){
    Ota.setSavedBundleDownloadURL( this._bundleDownloadURL = url );
  }

  get bundleDownloadURL(){
    return this._bundleDownloadURL;
  }

  get url(){
    return this._bundleDownloadURL + this.paramsWithHmac
  }

  get path(){
    return Ota.path;
  }

  md5( path ) {
    return new Promise(r=>Ota.md5( path, r ))
  }

  get remotebundle(){
    return this._remoteBundle;
  }

  getPackageInfo(){
    let path = this.path + '/bundle/bundle.info.json';
    return fs.exists( path )
    .then(isExist=>isExist ? fs.readFile( path ) : 'null')
    .then(result=>JSON.parse(result));
  }

  checkForUpdate( url, timeout = 5000 ){
    let timeoutRef = null;
    let options = {method:'POST', headers:{'Content-Type':'ping'} };
    return new Promise((resolve, reject)=>{
      let startTime = new Date();
      let rejector = (e, timeout)=>{
        if( e &&  e.message === 'Network request failed' ) reject( Object.assign(e, {requestFailed:true}) )
        if( timeoutRef ) {
          clearTimeout( timeoutRef );
          timeoutRef = null;
          reject(e);
        }
      };

      timeoutRef = setTimeout(()=>{
        rejector(new Error('Bundler Timeout'), true);
      }, timeout );

      fetch( url, options )
      .then(r=>{
        if( timeoutRef == null ) return;
        clearTimeout( timeoutRef );
        timeoutRef = null;
        resolve( r );
      })
      .catch(rejector)
    })
    .then(response=>response.json())
    .then(body=>{
      let {hash, size} = body;
      this._remoteBundle = {hash, size};
      return {
        success:!!hash,
        hash,
        size,
      }
    })
    .catch( e=>{
      // e && console.warn( 'Bundler::checkForUpdate', e );
      console.warn( e );
      return Promise.reject(e)
    })
  }

  download( hash, progressInterval = 100 ){
    let s = Date.now();
    let config = { path:this.path + '/' + hash,  trusty : true};
    return new Promise((resolve,reject)=>{
      let fetchObj = RNFetchBlob.config(config).fetch('POST', this.url);

      this._eventEmitter.emit( DownloadStartEvent );

      let timeoutRef = setTimeout(()=>{
        fetchObj.progress({interval:progressInterval},(received, total) => {
          this._eventEmitter.emit( DownloadProgressEvent, received / total, received, total);
        })
        clearTimeout( timeoutRef );
      },0);

      fetchObj.then((resp) => {
        this._eventEmitter.emit( DownloadProgressEvent, 1 );
        this._eventEmitter.emit( DownloadCompleteEvent );
        resolve( resp );
      })
      .catch(e => {
        e && console.warn( e );
        reject( e );
      })
    });
  }

  removeFile( filename ){
    if( !filename ) return Promise.resolve();

    let path = this.path + '/' + filename;
    return fs.exists( path )
    .then(exists=>{
      if( exists ) return fs.unlink( path );
    })
  }

  removeJS(){
    return Promise.all([
      this.removeFile( 'bundle/main.jsbundle' ),
      this.removeFile( 'bundle/main.jsbundle.meta' )
    ]).then(([r1,r2])=>{
    })
    .catch(e=>e && console.warn(e))
  }

  reloadApp(){
    Ota.reloadApp();
  }

  unzip( hash, overWrite = true) {
    return Ota.unzip( this.path + '/' + hash, this.path, overWrite )
  }

  addListener( event, listener, who ){
    if( !Events[event] ) return console.error( 'Bundler does not support event ' + event );

    let subscription = this._eventListeners.get(listener);
    if( subscription ) subscription.remove();

    subscription = this._eventEmitter.addListener( event, listener );
    this._eventListeners.set( listener, {subscription, who } );


    return subscription;
  }

  removeListener( listener ) {
    let subscription = this._eventListeners.get(listener);
    if( subscription ) {
      subscription.subscription.remove();
      this._eventListeners.delete( listener );
    }
  }

  checkUpdate( ask ){
    if( !Ota ) return Promise.resolve();
    let hash, oldHash;
    return this.synchronize()
    .then(()=>{
      oldHash = this.lastHash;
      return this.checkForUpdate( this.url )
    })
    .then(result=>{
      if( !result || !result.success ) return Promise.reject();

      if( result.hash == oldHash ) return Promise.reject(console.log( result.hash + ' is already have' ));

      hash = result.hash;
      result.currentHash = oldHash;
      return ask ? ask(result) : Promise.resolve();
    })
    .then(()=>this.download( hash )) // download
    .then(()=>this.unzip( hash ))    // unzip
    .then(()=>this.setLastHash( hash )) //
    .then(()=>this.removeFile( oldHash ))
    .then(()=>new Promise(r=>setTimeout( r, 1000 )))
    .then(()=>Ota.reloadApp())
    .catch(e=>{
      e && console.log( 'Bundler cancel because :: ', e )
      return Promise.resolve();
    })
  }
}

module.exports = new Bundler();

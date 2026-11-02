package dev.opendocs.opendocs

import android.content.*
import android.os.*
import io.flutter.plugin.common.MethodChannel

class SlideConversionClient(private val context: Context, private val channel: MethodChannel) {
    val isBusy: Boolean get() = result != null
    private var result: MethodChannel.Result? = null
    private var remote: Messenger? = null
    private var connection: ServiceConnection? = null
    private val handler = Handler(Looper.getMainLooper())
    private val timeout = Runnable { finish(null,"Slide conversion timed out. Try a smaller presentation.") }
    private val receiver = Messenger(Handler(Looper.getMainLooper()) { message ->
        when(message.what){
            2 -> finish(mapOf("path" to message.data.getString("path"),"pages" to message.data.getInt("pages"),"cached" to message.data.getBoolean("cached")),null)
            3 -> channel.invokeMethod("slideProgress",mapOf("completed" to message.data.getInt("completed"),"total" to message.data.getInt("total"),"stage" to message.data.getString("stage")))
            4 -> finish(null,message.data.getString("error")?:"Slide conversion failed.")
        }
        true
    })
    fun convert(path: String, callback: MethodChannel.Result) {
        if(result!=null){callback.error("BUSY","Another slide conversion is running.",null);return}
        result=callback
        val current=object:ServiceConnection{
            override fun onServiceConnected(name:ComponentName,binder:IBinder){
                remote=Messenger(binder)
                try { remote!!.send(Message.obtain(null,1).apply { data=Bundle().apply {putString("path",path)};replyTo=receiver }) }
                catch(_:RemoteException){finish(null,"Offline slide engine could not start.")}
            }
            override fun onServiceDisconnected(name:ComponentName){finish(null,"The slide engine stopped. This presentation may need more memory.")}
            override fun onNullBinding(name:ComponentName){finish(null,"Offline slide engine is unavailable.")}
        }
        connection=current
        try{
            if(!context.bindService(Intent(context,SlideConversionService::class.java),current,Context.BIND_AUTO_CREATE)){finish(null,"Offline slide engine is unavailable.");return}
            handler.postDelayed(timeout,180000)
        }catch(_:Exception){finish(null,"Offline slide engine is unavailable.")}
    }
    fun cancel(){try{remote?.send(Message.obtain(null,5))}catch(_:RemoteException){};finish(null,"Conversion cancelled.")}
    private fun finish(value:Map<String,Any?>?,error:String?){
        val callback=result?:return;result=null;handler.removeCallbacks(timeout)
        connection?.let { try{context.unbindService(it)}catch(_:Exception){} };connection=null;remote=null
        if(error!=null)callback.error("SLIDES",error,null) else callback.success(value)
    }
}

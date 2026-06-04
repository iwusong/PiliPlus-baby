package com.example.piliplus

import android.bluetooth.*
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.app.admin.DevicePolicyManager
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * Android 原生 BLE GATT Server 插件。
 *
 * ## 职责
 * - BLE 硬件能力检测 (isSupported)
 * - 蓝牙开关控制 (turnOn) + 状态监听 (adapterState)
 * - 创建 GATT Service + Characteristic
 * - 作为 BLE 外设广播广告
 * - 接收远程设备连接并透传 Characteristic 写入数据给 Flutter
 *
 * ## 与 Flutter 通信 (单 MethodChannel + 三条 EventChannel)
 * - MethodChannel "com.piliplus/gatt_server":
 *     start / stop / isAdvertising / isSupported / turnOn
 * - EventChannel ".../command":    推送收到的 Characteristic 写入数据
 * - EventChannel ".../connection": 推送连接/断开事件
 * - EventChannel ".../adapter":    推送蓝牙开关状态变化
 *
 * ## 注意
 * - GATT 回调默认在 Binder 线程执行, 需通过 Handler 切到主线程再调 EventChannel
 * - 本层不做任何数据校验/过滤, 纯透传
 */
class GattServerPlugin(
    private val activity: Context,
    flutterEngine: FlutterEngine
) {
    companion object {
        private const val TAG = "PiliPlus-BLE"

        /// GATT 服务 UUID, 广播中包含此 UUID 供扫描方识别
        val SERVICE_UUID = UUID.fromString("0000abcd-0000-1000-8000-00805f9b34fb")

        /// 命令特征值 UUID, 家长端通过 WRITE 操作向此特征值发送指令
        val CHAR_UUID = UUID.fromString("0000abce-0000-1000-8000-00805f9b34fb")

        // Flutter ↔ Native 通道名
        const val CHANNEL = "com.piliplus/gatt_server"
        const val EVENT_CMD = "com.piliplus/gatt_server/command"
        const val EVENT_CONN = "com.piliplus/gatt_server/connection"
        const val EVENT_ADAPTER = "com.piliplus/gatt_server/adapter"
    }

    private val appCtx = activity.applicationContext
    private val btManager: BluetoothManager =
        appCtx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager

    private var gattServer: BluetoothGattServer? = null
    private var isAdv = false
    private var cmdSink: EventChannel.EventSink? = null
    private var connSink: EventChannel.EventSink? = null
    private var adapterSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    /// 蓝牙开关状态广播接收器
    private val btStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val state = intent?.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                ?: BluetoothAdapter.ERROR
            val text = when (state) {
                BluetoothAdapter.STATE_ON -> "on"
                BluetoothAdapter.STATE_OFF -> "off"
                BluetoothAdapter.STATE_TURNING_ON -> "turningOn"
                BluetoothAdapter.STATE_TURNING_OFF -> "turningOff"
                else -> "unknown"
            }
            Log.d(TAG, "adapterState: $text")
            mainHandler.post { adapterSink?.success(text) }
        }
    }

    init {
        Log.d(TAG, "plugin created, btAdapter=${btManager.adapter}")

        // ---- MethodChannel: 接收 Flutter 的控制指令 ----
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(btManager.adapter != null)
                "getAdapterState" -> {
                    val s = when (btManager.adapter.state) {
                        BluetoothAdapter.STATE_ON -> "on"
                        BluetoothAdapter.STATE_OFF -> "off"
                        BluetoothAdapter.STATE_TURNING_ON -> "turningOn"
                        BluetoothAdapter.STATE_TURNING_OFF -> "turningOff"
                        else -> "unknown"
                    }
                    result.success(s)
                }
                "turnOn" -> {
                    val intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
                    activity.startActivity(intent)
                    result.success(true)
                }
                "start" -> start(call.argument("name"), result)
                "stop" -> stop(result)
                "lockScreen" -> lockScreen(result)
                "isAdvertising" -> result.success(isAdv)
                else -> result.notImplemented()
            }
        }

        // 注册蓝牙状态广播监听
        appCtx.registerReceiver(btStateReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))

        // ---- EventChannel: 推送蓝牙开关状态 ----
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_ADAPTER)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arg: Any?, events: EventChannel.EventSink?) {
                    Log.d(TAG, "EventChannel[adapter] onListen")
                    adapterSink = events
                }
                override fun onCancel(arg: Any?) {
                    Log.d(TAG, "EventChannel[adapter] onCancel")
                    adapterSink = null
                }
            })

        // ---- EventChannel: 推送收到的命令数据 ----
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CMD)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arg: Any?, events: EventChannel.EventSink?) {
                    Log.d(TAG, "EventChannel[cmd] onListen")
                    cmdSink = events
                }
                override fun onCancel(arg: Any?) {
                    Log.d(TAG, "EventChannel[cmd] onCancel")
                    cmdSink = null
                }
            })

        // ---- EventChannel: 推送连接/断开事件 ----
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CONN)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arg: Any?, events: EventChannel.EventSink?) {
                    Log.d(TAG, "EventChannel[conn] onListen")
                    connSink = events
                }
                override fun onCancel(arg: Any?) {
                    Log.d(TAG, "EventChannel[conn] onCancel")
                    connSink = null
                }
            })
    }

    /**
     * 启动 GATT Server + BLE 广播。
     *
     * 流程:
     * 1. 检查蓝牙是否开启
     * 2. 首次调用时创建 GATT Server, 添加 Service + Characteristic
     * 3. 设置设备蓝牙名称
     * 4. 开始 BLE 广播 (LOW_LATENCY 模式, 可连接, 含 Service UUID)
     *
     * @param name Flutter 传入的设备名, null 时默认 "PiliPlus"
     */
    private fun start(name: String?, result: MethodChannel.Result) {
        val deviceName = name ?: "PiliPlus"
        Log.d(TAG, "start() called, btOn=${btManager.adapter.isEnabled} isAdv=$isAdv name=$deviceName")
        if (!btManager.adapter.isEnabled) {
            result.error("BT_OFF", "Bluetooth is off", null)
            return
        }
        try {
            btManager.adapter.name = deviceName
            if (gattServer == null) {
                Log.d(TAG, "creating GattServer...")
                gattServer = btManager.openGattServer(appCtx, gattCallback)

                val svc = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
                val ch = BluetoothGattCharacteristic(
                    CHAR_UUID,
                    BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                    BluetoothGattCharacteristic.PERMISSION_WRITE
                )
                svc.addCharacteristic(ch)
                gattServer?.addService(svc)
                Log.d(TAG, "GattServer created, service added svc=$SERVICE_UUID ch=$CHAR_UUID")
            }
            if (isAdv) {
                Log.d(TAG, "already advertising, skip startAdvertising")
                result.success(true)
                return
            }
            val adv = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setConnectable(true)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .build()
            val data = AdvertiseData.Builder()
                .addServiceUuid(ParcelUuid(SERVICE_UUID))
                .setIncludeDeviceName(true)
                .build()
            Log.d(TAG, "starting advertising... svc=$SERVICE_UUID connectable=true")
            btManager.adapter.bluetoothLeAdvertiser.startAdvertising(adv, data, advanceCallback)
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "start failed: ${e.message}", e)
            result.error("START_FAILED", e.message, null)
        }
    }

    /// 调用系统锁屏, 需要设备管理员权限
    private fun lockScreen(result: MethodChannel.Result) {
        Log.d(TAG, "lockScreen()")
        try {
            val dpm = appCtx.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            dpm.lockNow()
            result.success(true)
        } catch (e: SecurityException) {
            Log.e(TAG, "lockScreen failed: not device admin", e)
            result.error("NOT_ADMIN", "需先在设置中激活设备管理器", null)
        }
    }

    /// 停止广播并关闭 GATT Server
    private fun stop(result: MethodChannel.Result) {
        Log.d(TAG, "stop()")
        try {
            btManager.adapter.bluetoothLeAdvertiser.stopAdvertising(advanceCallback)
            gattServer?.close()
            gattServer = null
            isAdv = false
            Log.d(TAG, "stopped")
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "stop failed: ${e.message}", e)
            result.error("STOP_FAILED", e.message, null)
        }
    }

    // ============================================================
    //  BLE 回调
    // ============================================================

    private val gattCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(dev: BluetoothDevice, status: Int, newState: Int) {
            val stateName = if (newState == BluetoothProfile.STATE_CONNECTED) "CONNECTED" else "DISCONNECTED"
            val deviceName = dev.name ?: dev.address
            Log.d(TAG, "onConnectionStateChange: $stateName dev=$deviceName ($dev.address) status=$status")
            val connected = newState == BluetoothProfile.STATE_CONNECTED
            mainHandler.post {
                connSink?.success(mapOf(
                    "device" to dev.address,
                    "name" to (dev.name ?: dev.address),
                    "connected" to connected
                ))
            }
        }

        override fun onCharacteristicWriteRequest(
            dev: BluetoothDevice, requestId: Int, ch: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray
        ) {
            val hex = value.joinToString("") { "%02x".format(it) }
            val deviceName = dev.name ?: dev.address
            Log.d(TAG, "onWriteRequest: dev=$deviceName uuid=${ch.uuid} value=0x$hex responseNeeded=$responseNeeded")
            if (ch.uuid == CHAR_UUID) {
                mainHandler.post {
                    cmdSink?.success(mapOf("address" to dev.address, "value" to value))
                }
            }
            if (responseNeeded) {
                gattServer?.sendResponse(dev, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }
    }

    private val advanceCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            isAdv = true
            Log.d(TAG, "advertising STARTED: mode=${settingsInEffect?.mode} tx=${settingsInEffect?.txPowerLevel} connectable=${settingsInEffect?.isConnectable}")
        }
        override fun onStartFailure(errorCode: Int) {
            isAdv = false
            val msg = when (errorCode) {
                AdvertiseCallback.ADVERTISE_FAILED_DATA_TOO_LARGE -> "DATA_TOO_LARGE"
                AdvertiseCallback.ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "TOO_MANY_ADVERTISERS"
                AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED -> "ALREADY_STARTED"
                AdvertiseCallback.ADVERTISE_FAILED_INTERNAL_ERROR -> "INTERNAL_ERROR"
                AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "FEATURE_UNSUPPORTED"
                else -> "UNKNOWN($errorCode)"
            }
            Log.e(TAG, "advertising FAILED: $msg")
        }
    }
}

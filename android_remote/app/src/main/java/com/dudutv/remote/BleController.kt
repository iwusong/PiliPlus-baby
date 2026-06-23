package com.dudutv.remote

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class BleController(
    private val context: Context,
    private val onDeviceFound: (ScanResult) -> Unit,
    private val onConnectionState: (String, Boolean) -> Unit,
) {
    companion object {
        private const val TAG = "PiliPlusRemote"
        val SERVICE_UUID = UUID.fromString("0000abcd-0000-1000-8000-00805f9b34fb")
        val CHAR_UUID = UUID.fromString("0000abce-0000-1000-8000-00805f9b34fb")
    }

    private val btManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val btAdapter = btManager.adapter
    private val scanner = btAdapter.bluetoothLeScanner
    private val mainHandler = Handler(Looper.getMainLooper())

    private var bluetoothGatt: BluetoothGatt? = null
    private var commandChar: BluetoothGattCharacteristic? = null
    val isConnected get() = bluetoothGatt != null

    private val devices = ConcurrentHashMap<String, ScanResult>()

    @SuppressLint("MissingPermission")
    fun startScan() {
        if (!btAdapter.isEnabled) return
        devices.clear()
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .build()
        scanner.startScan(listOf(filter), settings, scanCallback)
    }

    @SuppressLint("MissingPermission")
    fun stopScan() {
        scanner.stopScan(scanCallback)
    }

    @SuppressLint("MissingPermission")
    fun connect(result: ScanResult) {
        stopScan()
        disconnect()
        val dev = result.device
        bluetoothGatt = dev.connectGatt(context, false, gattCallback)
    }

    @SuppressLint("MissingPermission")
    fun disconnect() {
        bluetoothGatt?.disconnect()
        bluetoothGatt?.close()
        bluetoothGatt = null
        commandChar = null
    }

    @SuppressLint("MissingPermission")
    fun sendCommand(cmd: Byte) {
        val char = commandChar ?: return
        val data = byteArrayOf(0xAA.toByte(), cmd, 0x50, 0x49)
        bluetoothGatt?.writeCharacteristic(
            char, data, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        )
    }

    @SuppressLint("MissingPermission")
    fun sendSpeed(idx: Byte) {
        val char = commandChar ?: return
        val data = byteArrayOf(0xAA.toByte(), 0x09, 0x50, 0x49, idx)
        bluetoothGatt?.writeCharacteristic(
            char, data, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        )
    }

    fun close() {
        disconnect()
        stopScan()
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val addr = result.device.address
            if (devices.containsKey(addr)) return
            devices[addr] = result
            mainHandler.post { onDeviceFound(result) }
        }
        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "scan failed: $errorCode")
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val connected = newState == BluetoothProfile.STATE_CONNECTED
            Log.d(TAG, "conn: $connected status=$status")
            if (connected && status == BluetoothGatt.GATT_SUCCESS) {
                gatt.discoverServices()
            } else {
                bluetoothGatt = null
                commandChar = null
            }
            mainHandler.post {
                onConnectionState(
                    gatt.device.name ?: gatt.device.address,
                    connected
                )
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "discover failed: $status")
                return
            }
            val svc = gatt.getService(SERVICE_UUID)
            val char = svc?.getCharacteristic(CHAR_UUID)
            if (svc != null && char != null) {
                commandChar = char
                Log.d(TAG, "ready to send commands")
            } else {
                Log.e(TAG, "service/char not found")
                gatt.disconnect()
            }
        }
    }
}

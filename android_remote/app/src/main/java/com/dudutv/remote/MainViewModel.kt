package com.dudutv.remote

import android.bluetooth.le.ScanResult
import androidx.lifecycle.ViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class MainViewModel : ViewModel() {
    data class UiState(
        val devices: List<ScanResult> = emptyList(),
        val connectedDevice: String? = null,
        val isConnected: Boolean = false,
        val isScanning: Boolean = false,
    )

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    fun addDevice(device: ScanResult) {
        _state.value = _state.value.copy(
            devices = _state.value.devices + device
        )
    }

    fun clearDevices() {
        _state.value = _state.value.copy(devices = emptyList())
    }

    fun setScanning(scanning: Boolean) {
        _state.value = _state.value.copy(isScanning = scanning)
    }

    fun setConnection(name: String?, connected: Boolean) {
        _state.value = _state.value.copy(
            connectedDevice = if (connected) name else null,
            isConnected = connected,
        )
    }
}

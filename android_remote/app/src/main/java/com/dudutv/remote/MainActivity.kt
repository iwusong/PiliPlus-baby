package com.dudutv.remote

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.recyclerview.widget.DividerItemDecoration
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.dudutv.remote.databinding.ActivityMainBinding
import com.dudutv.remote.databinding.ItemDeviceBinding
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var viewModel: MainViewModel
    private lateinit var bleController: BleController

    private var autoConnected = false

    private val btEnableLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) {
        bleController.startScan()
        autoConnected = false
    }

    private val permLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { perms ->
        if (perms.all { it.value }) startBle() else finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        viewModel = ViewModelProvider(this)[MainViewModel::class.java]

        bleController = BleController(
            context = this,
            onDeviceFound = { result ->
                viewModel.addDevice(result)
                if (!autoConnected && !viewModel.state.value.isConnected) {
                    autoConnected = true
                    bleController.connect(result)
                }
            },
            onConnectionState = { name, connected ->
                viewModel.setConnection(name, connected)
                if (!connected) autoConnected = false
            }
        )

        setupRecyclerView()
        setupButtons()
        observeState()
        requestPermissions()
    }

    override fun onDestroy() {
        super.onDestroy()
        bleController.close()
    }

    private fun requestPermissions() {
        val needed = buildList {
            if (Build.VERSION.SDK_INT >= 31) {
                add(Manifest.permission.BLUETOOTH_SCAN)
                add(Manifest.permission.BLUETOOTH_CONNECT)
            } else {
                @Suppress("DEPRECATION")
                add(Manifest.permission.ACCESS_FINE_LOCATION)
            }
        }
        val missing = needed.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) {
            permLauncher.launch(missing.toTypedArray())
        } else {
            startBle()
        }
    }

    @SuppressLint("MissingPermission")
    private fun startBle() {
        val adapter = (getSystemService(BLUETOOTH_SERVICE) as BluetoothManager).adapter
        if (!adapter.isEnabled) {
            btEnableLauncher.launch(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
        } else {
            viewModel.clearDevices()
            bleController.startScan()
            viewModel.setScanning(true)
        }
    }

    private fun setupRecyclerView() {
        binding.deviceList.layoutManager = LinearLayoutManager(this)
        binding.deviceList.addItemDecoration(
            DividerItemDecoration(this, DividerItemDecoration.VERTICAL)
        )
        binding.deviceList.adapter = DeviceAdapter { device ->
            bleController.connect(device)
        }
    }

    @SuppressLint("MissingPermission")
    private fun setupButtons() {
        binding.scanBtn.setOnClickListener {
            if (viewModel.state.value.isScanning) {
                bleController.stopScan()
                viewModel.setScanning(false)
            } else {
                autoConnected = false
                startBle()
            }
        }
        binding.btnBatteryOut.setOnClickListener { bleController.sendCommand(0x00) }
        binding.btnPause.setOnClickListener { bleController.sendCommand(0x01) }
        binding.btnLockScreen.setOnClickListener { bleController.sendCommand(0x02) }
        binding.btnResume.setOnClickListener { bleController.sendCommand(0x03) }
        binding.btnDisconnect.setOnClickListener {
            autoConnected = false
            bleController.disconnect()
            viewModel.setConnection(null, false)
        }
    }

    private fun observeState() {
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.state.collectLatest { state ->
                    (binding.deviceList.adapter as DeviceAdapter).submitList(state.devices)

                    if (state.isConnected) {
                        binding.scanSection.visibility = android.view.View.GONE
                        binding.controlSection.visibility = android.view.View.VISIBLE
                        binding.connTitle.text = state.connectedDevice ?: "已连接"
                    } else {
                        binding.scanSection.visibility = android.view.View.VISIBLE
                        binding.controlSection.visibility = android.view.View.GONE
                        binding.connTitle.text = "未连接"
                    }

                    binding.scanBtn.text = if (state.isScanning) "扫描中..." else "开始扫描"
                }
            }
        }
    }

    private class DeviceAdapter(
        private val onClick: (android.bluetooth.le.ScanResult) -> Unit
    ) : androidx.recyclerview.widget.RecyclerView.Adapter<DeviceAdapter.ViewHolder>() {

        private var items = listOf<android.bluetooth.le.ScanResult>()

        fun submitList(list: List<android.bluetooth.le.ScanResult>) {
            items = list
            notifyDataSetChanged()
        }

        override fun onCreateViewHolder(parent: ViewGroup, type: Int): ViewHolder {
            val binding = ItemDeviceBinding.inflate(
                LayoutInflater.from(parent.context), parent, false
            )
            return ViewHolder(binding)
        }

        override fun onBindViewHolder(holder: ViewHolder, pos: Int) {
            val r = items[pos]
            val name = r.device.name ?: "Unknown"
            val rssi = r.rssi
            holder.binding.deviceName.text = name
            holder.binding.deviceAddr.text = "${r.device.address}  RSSI: $rssi dBm"
            holder.binding.root.setOnClickListener { onClick(r) }
        }

        override fun getItemCount() = items.size

        class ViewHolder(val binding: ItemDeviceBinding) :
            RecyclerView.ViewHolder(binding.root)
    }
}

use clap::{Parser, Subcommand};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};
use sysinfo::System;

/// System Inspector & Disk Wiper for Netboot Environments
#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Inspects system hardware and outputs YAML (default)
    Inspect,
    /// Destructively wipes all found physical block devices
    Wipe {
        /// Confirmation flag required to execute wipe
        #[arg(long)]
        confirm: bool,
    },
}

#[derive(Serialize)]
struct InspectorReport {
    system: SystemResources,
    block_devices: Vec<BlockDevice>,
    network_devices: Vec<NetworkDevice>,
    pci_devices: Vec<PciDevice>,
}

#[derive(Serialize)]
struct SystemResources {
    total_memory_bytes: u64,
    cpu_model: String,
    cpu_cores: usize,
}

#[derive(Serialize, Deserialize, Clone)]
struct BlockDevice {
    name: String,
    size_bytes: u64,
    model: Option<String>,
    transport: Option<String>,
    serial: Option<String>,
    #[serde(skip_serializing)]
    read_only: bool,
}

#[derive(Serialize)]
struct NetworkDevice {
    name: String,
    mac_address: String,
    speed_mbps: Option<i64>,
    driver: Option<String>,
}

#[derive(Serialize)]
struct PciDevice {
    slot: String,
    class: String,
    vendor: String,
    device: String,
}

fn main() {
    let cli = Cli::parse();

    match cli.command.unwrap_or(Commands::Inspect) {
        Commands::Inspect => run_inspect(),
        Commands::Wipe { confirm } => run_wipe(confirm),
    }
}

fn run_inspect() {
    let mut sys = System::new_all();
    sys.refresh_all();

    let cpu_model = sys
        .cpus()
        .first()
        .map(|cpu| cpu.brand().to_string())
        .unwrap_or_else(|| "Unknown".to_string());

    let system_res = SystemResources {
        total_memory_bytes: sys.total_memory(),
        cpu_model,
        cpu_cores: sys.cpus().len(),
    };

    let report = InspectorReport {
        system: system_res,
        block_devices: get_block_devices(),
        network_devices: get_network_devices(),
        pci_devices: get_pci_devices(),
    };

    match serde_yaml::to_string(&report) {
        Ok(yaml) => println!("{}", yaml),
        Err(e) => eprintln!("Failed to serialize report: {}", e),
    }
}

fn run_wipe(confirm: bool) {
    if !confirm {
        eprintln!("ERROR: You must pass --confirm to wipe devices.");
        std::process::exit(1);
    }

    println!("Starting Disk Wipe (Netboot Mode)...");

    // In a netboot environment, we assume the OS is in RAM.
    // We wipe ALL physical read-write block devices.
    let devices = get_block_devices();

    if devices.is_empty() {
        println!("No block devices found.");
        return;
    }

    for dev in devices {
        // Safety: Skip Read-Only devices (like CD-ROMs or protected USBs)
        if dev.read_only {
            println!("Skipping Read-Only device: /dev/{}", dev.name);
            continue;
        }

        // Safety: Skip obvious non-physical devices if lsblk categorized them as disk
        if dev.name.starts_with("loop")
            || dev.name.starts_with("ram")
            || dev.name.starts_with("zram")
        {
            println!("Skipping virtual device: /dev/{}", dev.name);
            continue;
        }

        println!(
            "Wiping /dev/{} ({}, {} bytes)...",
            dev.name,
            dev.model.as_deref().unwrap_or("Unknown Model"),
            dev.size_bytes
        );

        // 1. Wipe Filesystem Signatures
        let status_wipefs = Command::new("wipefs")
            .args(&["-a", &format!("/dev/{}", dev.name)])
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .status();

        // 2. Zap GPT/MBR tables
        let status_sgdisk = Command::new("sgdisk")
            .args(&["--zap-all", &format!("/dev/{}", dev.name)])
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .status();

        match (status_wipefs, status_sgdisk) {
            (Ok(w), Ok(s)) if w.success() && s.success() => {
                println!("  -> Successfully wiped /dev/{}", dev.name);
            }
            (Ok(w), Ok(s)) => {
                println!(
                    "  -> Warning: Issues encountered (wipefs: {}, sgdisk: {})",
                    w, s
                );
            }
            _ => {
                eprintln!(
                    "  -> FATAL: Failed to execute wipe commands on /dev/{}",
                    dev.name
                );
            }
        }
    }

    println!("Syncing disks...");
    let _ = Command::new("sync").status();

    println!("Notifying kernel of partition changes...");
    let _ = Command::new("partprobe").status();

    println!("Wipe complete.");
}

// --- Helper Functions ---

fn get_block_devices() -> Vec<BlockDevice> {
    // lsblk args:
    // -J: JSON output
    // -b: Bytes for size
    // -o: Columns
    let output = Command::new("lsblk")
        .args(&["-J", "-b", "-o", "NAME,SIZE,MODEL,TRAN,SERIAL,TYPE,RO"])
        .output();

    #[derive(Deserialize)]
    struct LsblkOutput {
        blockdevices: Vec<LsblkDevice>,
    }

    #[derive(Deserialize)]
    struct LsblkDevice {
        name: String,
        #[serde(deserialize_with = "parse_size")]
        size: u64,
        model: Option<String>,
        tran: Option<String>,
        serial: Option<String>,
        #[serde(rename = "type")]
        dev_type: String,
        #[serde(deserialize_with = "parse_bool")]
        ro: bool,
    }

    // Helper for size parsing
    fn parse_size<'de, D>(deserializer: D) -> Result<u64, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let v: serde_json::Value = Deserialize::deserialize(deserializer)?;
        if let Some(n) = v.as_u64() {
            Ok(n)
        } else if let Some(s) = v.as_str() {
            s.parse::<u64>().map_err(serde::de::Error::custom)
        } else {
            Ok(0)
        }
    }

    // Helper for boolean parsing (lsblk can return "0"/"1" or true/false)
    fn parse_bool<'de, D>(deserializer: D) -> Result<bool, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let v: serde_json::Value = Deserialize::deserialize(deserializer)?;
        match v {
            serde_json::Value::Bool(b) => Ok(b),
            serde_json::Value::String(s) => Ok(s == "true" || s == "1"),
            serde_json::Value::Number(n) => Ok(n.as_u64() == Some(1)),
            _ => Ok(false),
        }
    }

    match output {
        Ok(out) if out.status.success() => {
            let output_str = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<LsblkOutput>(&output_str) {
                // Filter specifically for "disk" type to ignore partitions/loops
                parsed
                    .blockdevices
                    .into_iter()
                    .filter(|d| d.dev_type == "disk")
                    .map(|d| BlockDevice {
                        name: d.name,
                        size_bytes: d.size,
                        model: d.model,
                        transport: d.tran,
                        serial: d.serial,
                        read_only: d.ro,
                    })
                    .collect()
            } else {
                eprintln!("Error: Failed to parse lsblk output.");
                vec![]
            }
        }
        _ => {
            eprintln!("Error: Failed to run lsblk.");
            vec![]
        }
    }
}

fn get_network_devices() -> Vec<NetworkDevice> {
    let mut devices = Vec::new();
    let net_path = Path::new("/sys/class/net");

    if let Ok(entries) = fs::read_dir(net_path) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            let dev_path = entry.path();

            if name == "lo" {
                continue;
            }
            if !dev_path.join("device").exists() {
                continue;
            }

            let mac_address = fs::read_to_string(dev_path.join("address"))
                .unwrap_or_default()
                .trim()
                .to_string();

            let speed_mbps = fs::read_to_string(dev_path.join("speed"))
                .ok()
                .and_then(|s| s.trim().parse::<i64>().ok());

            let driver = fs::read_link(dev_path.join("device/driver"))
                .ok()
                .map(|p| p.file_name().unwrap().to_string_lossy().to_string());

            devices.push(NetworkDevice {
                name,
                mac_address,
                speed_mbps,
                driver,
            });
        }
    }
    devices
}

fn get_pci_devices() -> Vec<PciDevice> {
    // lspci -mm: "Slot" "Class" "Vendor" "Device"
    let output = Command::new("lspci").arg("-mm").output();

    let mut devices = Vec::new();

    if let Ok(out) = output {
        let stdout = String::from_utf8_lossy(&out.stdout);
        for line in stdout.lines() {
            let parts: Vec<&str> = line.split("\" \"").collect();
            if parts.len() >= 4 {
                devices.push(PciDevice {
                    slot: parts[0].trim_matches('"').to_string(),
                    class: parts[1].trim_matches('"').to_string(),
                    vendor: parts[2].trim_matches('"').to_string(),
                    device: parts[3].trim_matches('"').to_string(),
                });
            }
        }
    }
    devices
}

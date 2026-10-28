//! Import a LoRA adapter trained with MLX into the engine's GGUF format.
//!
//! Specialists are trained on Apple Silicon with MLX-LM (ADR 0009) and served
//! by the engine (llama.cpp), which loads adapters as GGUF files. The two
//! store the same matrices under different names and, for ordinary linear
//! layers, transposed. This converts one into the other without Python.
//!
//! Only what is understood is converted. An adapter tensor with no known
//! counterpart in the base model is an error, never silently dropped: a
//! half-applied adapter is a different model that still loads.
//!
//! MLX-LM computes `y = x·Wᵀ + scale · (x·A)·B` with `A: (in, r)` and
//! `B: (r, out)` for a linear layer, and `A: (experts, r, in)`,
//! `B: (experts, out, r)` for a mixture-of-experts layer. llama.cpp expects
//! `lora_a` with ggml shape `[in, r]` and `lora_b` with `[r, out]` (numpy
//! order reversed), plus an expert axis last, and scales by `alpha / r`. So
//! linear matrices are transposed, expert matrices are copied as they are, and
//! `alpha = scale · r`.

use std::collections::BTreeMap;
use std::io::Write as _;
use std::path::Path;

use serde::Deserialize;

#[derive(Debug)]
pub struct ImportError(pub String);

impl std::fmt::Display for ImportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ImportError {}

fn fail(message: impl Into<String>) -> ImportError {
    ImportError(message.into())
}

/// What was imported, for the deployment record.
#[derive(Debug, Clone, PartialEq)]
pub struct Imported {
    pub architecture: &'static str,
    pub rank: u32,
    pub alpha: f32,
    pub tensors: usize,
    /// The layers the adapter touches, lowest first.
    pub layers: Vec<u32>,
    /// The MLX base model it was trained on, as its config names it.
    pub trained_on: String,
}

#[derive(Deserialize)]
struct MlxConfig {
    fine_tune_type: String,
    model: String,
    lora_parameters: MlxLora,
}

#[derive(Deserialize)]
struct MlxLora {
    rank: u32,
    scale: f32,
}

/// An MLX module path, its GGUF tensor name, and whether the module is a
/// per-expert (switch) layer.
type ModuleMap = &'static [(&'static str, &'static str, bool)];

/// gpt-oss's modules.
const GPT_OSS: ModuleMap = &[
    ("self_attn.q_proj", "attn_q", false),
    ("self_attn.k_proj", "attn_k", false),
    ("self_attn.v_proj", "attn_v", false),
    ("self_attn.o_proj", "attn_output", false),
    ("mlp.router", "ffn_gate_inp", false),
    ("mlp.experts.gate_proj", "ffn_gate_exps", true),
    ("mlp.experts.up_proj", "ffn_up_exps", true),
    ("mlp.experts.down_proj", "ffn_down_exps", true),
];

/// Qwen3.5's modules. Three in four layers are linear attention (gated
/// delta-net), the fourth full attention; llama.cpp names the linear ones'
/// projections after their role in the state-space update.
const QWEN35: ModuleMap = &[
    ("self_attn.q_proj", "attn_q", false),
    ("self_attn.k_proj", "attn_k", false),
    ("self_attn.v_proj", "attn_v", false),
    ("self_attn.o_proj", "attn_output", false),
    ("linear_attn.in_proj_qkv", "attn_qkv", false),
    ("linear_attn.in_proj_z", "attn_gate", false),
    ("linear_attn.in_proj_a", "ssm_alpha", false),
    ("linear_attn.in_proj_b", "ssm_beta", false),
    ("linear_attn.out_proj", "ssm_out", false),
    ("mlp.gate_proj", "ffn_gate", false),
    ("mlp.up_proj", "ffn_up", false),
    ("mlp.down_proj", "ffn_down", false),
];

/// The architectures this can import, by the name the engine's GGUF uses.
fn table(architecture: &str) -> Option<(&'static str, ModuleMap)> {
    match architecture {
        "gpt-oss" => Some(("gpt-oss", GPT_OSS)),
        "qwen35" => Some(("qwen35", QWEN35)),
        _ => None,
    }
}

struct Tensor {
    shape: Vec<usize>,
    data: Vec<f32>,
}

/// Read an MLX adapter directory (`adapter_config.json` and
/// `adapters.safetensors`) and write a llama.cpp LoRA GGUF to `out`.
pub fn import_mlx_lora(
    dir: &Path,
    architecture: &str,
    base: Option<&Path>,
    out: &Path,
) -> Result<Imported, ImportError> {
    let (arch, modules) = table(architecture).ok_or_else(|| {
        fail(format!(
            "importing adapters for `{architecture}` is not supported yet; gpt-oss and qwen35 are"
        ))
    })?;

    let config_path = dir.join("adapter_config.json");
    let config: MlxConfig = serde_json::from_slice(
        &std::fs::read(&config_path)
            .map_err(|err| fail(format!("{}: {err}", config_path.display())))?,
    )
    .map_err(|err| fail(format!("{}: {err}", config_path.display())))?;
    if config.fine_tune_type != "lora" {
        return Err(fail(format!(
            "only LoRA adapters can be imported, and this one is `{}`",
            config.fine_tune_type
        )));
    }
    let rank = config.lora_parameters.rank;
    let alpha = config.lora_parameters.scale * rank as f32;

    // Qwen3.5's GGUF stores the linear-attention value heads in another order
    // than the MLX weights the adapter was trained on; its head counts come
    // from the base model the adapter will run on.
    let layout = match arch {
        "qwen35" => Some(ValueHeads::from_base(base.ok_or_else(|| {
            fail("a qwen35 adapter needs --base <the GGUF it will run on>, for its head layout")
        })?)?),
        _ => None,
    };

    let weights = dir.join("adapters.safetensors");
    let source = read_safetensors(&weights)?;

    // Pair every lora_a with its lora_b under the GGUF name of the weight
    // they adapt.
    let mut converted: BTreeMap<String, Tensor> = BTreeMap::new();
    let mut layers = std::collections::BTreeSet::new();
    for (name, tensor) in source {
        let (stem, half) = name
            .rsplit_once('.')
            .filter(|(_, half)| *half == "lora_a" || *half == "lora_b")
            .ok_or_else(|| fail(format!("`{name}` is not a LoRA tensor")))?;
        let rest = stem
            // A vision-language model keeps its text model under
            // `language_model`; the adapter only ever touches that part.
            .strip_prefix("language_model.model.layers.")
            .or_else(|| stem.strip_prefix("model.layers."))
            .ok_or_else(|| fail(format!("`{name}` is not inside a transformer layer")))?;
        let (layer, module) = rest
            .split_once('.')
            .ok_or_else(|| fail(format!("`{name}` has no module path")))?;
        let layer: u32 = layer
            .parse()
            .map_err(|_| fail(format!("`{name}` has no layer number")))?;
        let &(_, gguf, experts) = modules
            .iter()
            .find(|(mlx, _, _)| *mlx == module)
            .ok_or_else(|| {
                fail(format!(
                    "`{name}` adapts `{module}`, which has no counterpart in {arch}"
                ))
            })?;

        let tensor = if experts {
            if tensor.shape.len() != 3 {
                return Err(fail(format!(
                    "`{name}` should be per-expert (3 dimensions)"
                )));
            }
            tensor
        } else {
            if tensor.shape.len() != 2 {
                return Err(fail(format!("`{name}` should be a matrix (2 dimensions)")));
            }
            transpose(tensor)
        };
        let rank_axis = if half == "lora_a" {
            tensor.shape[tensor.shape.len() - 2]
        } else {
            tensor.shape[tensor.shape.len() - 1]
        };
        if rank_axis != rank as usize {
            return Err(fail(format!(
                "`{name}` has rank {rank_axis}, but the adapter says {rank}"
            )));
        }
        let tensor = match &layout {
            Some(layout) => layout.reorder(gguf, half, tensor, &name)?,
            None => tensor,
        };
        layers.insert(layer);
        converted.insert(format!("blk.{layer}.{gguf}.weight.{half}"), tensor);
    }
    for name in converted.keys() {
        let other = name
            .strip_suffix(".lora_a")
            .map(|base| format!("{base}.lora_b"))
            .or_else(|| {
                name.strip_suffix(".lora_b")
                    .map(|base| format!("{base}.lora_a"))
            });
        if other.is_some_and(|other| !converted.contains_key(&other)) {
            return Err(fail(format!("`{name}` has no matching half")));
        }
    }

    write_gguf(out, arch, alpha, &converted)?;
    Ok(Imported {
        architecture: arch,
        rank,
        alpha,
        tensors: converted.len(),
        layers: layers.into_iter().collect(),
        trained_on: config.model,
    })
}

/// Qwen3.5's linear-attention value heads, as its GGUF lays them out.
///
/// MLX keeps each key head's value heads together (key head `g` owns value
/// heads `g*r .. g*r + r`, with `r` value heads per key head). llama.cpp's
/// converter stores them tiled instead: GGUF value head `i` is MLX value head
/// `(i % k) * r + i / k` for `k` key heads. Measured on Qwen3.5-4B: rows
/// matched at 0.995 correlation under this order and not without it, in
/// `attn_qkv`'s value block, `attn_gate`, `ssm_alpha`, `ssm_beta` and
/// `ssm_out`'s inputs. Query and key rows, full attention and the MLP are
/// stored as MLX has them.
#[derive(Debug, Clone, Copy, PartialEq)]
struct ValueHeads {
    key_heads: usize,
    value_heads: usize,
    key_dim: usize,
    value_dim: usize,
}

impl ValueHeads {
    fn from_base(base: &Path) -> Result<Self, ImportError> {
        let meta = gguf_metadata(
            base,
            &[
                "general.architecture",
                "qwen35.ssm.group_count",
                "qwen35.ssm.time_step_rank",
                "qwen35.ssm.inner_size",
                "qwen35.ssm.state_size",
            ],
        )?;
        let get = |key: &str| {
            meta.get(key)
                .and_then(|value| value.parse::<usize>().ok())
                .filter(|value| *value > 0)
                .ok_or_else(|| fail(format!("{} has no {key}", base.display())))
        };
        if meta.get("general.architecture").map(String::as_str) != Some("qwen35") {
            return Err(fail(format!("{} is not a qwen35 model", base.display())));
        }
        let key_heads = get("qwen35.ssm.group_count")?;
        let value_heads = get("qwen35.ssm.time_step_rank")?;
        let inner = get("qwen35.ssm.inner_size")?;
        let key_dim = get("qwen35.ssm.state_size")?;
        if value_heads % key_heads != 0 || inner % value_heads != 0 {
            return Err(fail("the base model's head counts do not divide evenly"));
        }
        Ok(Self {
            key_heads,
            value_heads,
            key_dim,
            value_dim: inner / value_heads,
        })
    }

    /// Where GGUF value head `i` comes from in MLX order.
    fn source(&self, i: usize) -> usize {
        let per_key = self.value_heads / self.key_heads;
        (i % self.key_heads) * per_key + i / self.key_heads
    }

    /// Put one converted tensor (numpy layout: `lora_a` is `(r, in)`,
    /// `lora_b` is `(out, r)`) into GGUF head order where it needs it.
    fn reorder(
        &self,
        gguf: &str,
        half: &str,
        tensor: Tensor,
        name: &str,
    ) -> Result<Tensor, ImportError> {
        let value_total = self.value_heads * self.value_dim;
        let (axis, start, block, expected) = match (gguf, half) {
            ("attn_qkv", "lora_b") => (
                0,
                2 * self.key_heads * self.key_dim,
                self.value_dim,
                2 * self.key_heads * self.key_dim + value_total,
            ),
            ("attn_gate", "lora_b") => (0, 0, self.value_dim, value_total),
            ("ssm_alpha" | "ssm_beta", "lora_b") => (0, 0, 1, self.value_heads),
            ("ssm_out", "lora_a") => (1, 0, self.value_dim, value_total),
            _ => return Ok(tensor),
        };
        if tensor.shape[axis] != expected {
            return Err(fail(format!(
                "`{name}` has {} along its head axis, but the base model's layout needs {expected}",
                tensor.shape[axis]
            )));
        }
        let (rows, cols) = (tensor.shape[0], tensor.shape[1]);
        let mut data = tensor.data.clone();
        for head in 0..self.value_heads {
            let from = start + self.source(head) * block;
            let to = start + head * block;
            for offset in 0..block {
                if axis == 0 {
                    let (src, dst) = ((from + offset) * cols, (to + offset) * cols);
                    data[dst..dst + cols].copy_from_slice(&tensor.data[src..src + cols]);
                } else {
                    for row in 0..rows {
                        data[row * cols + to + offset] = tensor.data[row * cols + from + offset];
                    }
                }
            }
        }
        Ok(Tensor {
            shape: tensor.shape,
            data,
        })
    }
}

/// String and integer metadata from a GGUF header, for the keys asked for.
/// Values are skipped without being kept, so a header with a large
/// vocabulary costs a scan, not its size in memory.
fn gguf_metadata(path: &Path, keys: &[&str]) -> Result<BTreeMap<String, String>, ImportError> {
    use std::io::Read as _;
    let file =
        std::fs::File::open(path).map_err(|err| fail(format!("{}: {err}", path.display())))?;
    let mut reader = std::io::BufReader::new(file);
    let bad = || fail(format!("{} is not a readable GGUF file", path.display()));
    let read = |len: usize,
                reader: &mut std::io::BufReader<std::fs::File>|
     -> Result<Vec<u8>, ImportError> {
        let mut buf = vec![0u8; len];
        reader.read_exact(&mut buf).map_err(|_| bad())?;
        Ok(buf)
    };
    let u32_of = |bytes: Vec<u8>| u32::from_le_bytes(bytes[..4].try_into().unwrap_or_default());
    let u64_of = |bytes: Vec<u8>| u64::from_le_bytes(bytes[..8].try_into().unwrap_or_default());
    if read(4, &mut reader)? != b"GGUF" {
        return Err(bad());
    }
    let _version = read(4, &mut reader)?;
    let _tensors = read(8, &mut reader)?;
    let count = u64_of(read(8, &mut reader)?);

    fn scalar_size(kind: u32) -> Option<usize> {
        match kind {
            0 | 1 | 7 => Some(1),
            2 | 3 => Some(2),
            4..=6 => Some(4),
            10..=12 => Some(8),
            _ => None,
        }
    }
    let mut found = BTreeMap::new();
    for _ in 0..count {
        let len = u64_of(read(8, &mut reader)?) as usize;
        let key = String::from_utf8(read(len, &mut reader)?).map_err(|_| bad())?;
        let kind = u32_of(read(4, &mut reader)?);
        let wanted = keys.contains(&key.as_str());
        match kind {
            8 => {
                let len = u64_of(read(8, &mut reader)?) as usize;
                let value = read(len, &mut reader)?;
                if wanted {
                    found.insert(key, String::from_utf8_lossy(&value).into_owned());
                }
            }
            9 => {
                let inner = u32_of(read(4, &mut reader)?);
                let items = u64_of(read(8, &mut reader)?);
                for _ in 0..items {
                    if inner == 8 {
                        let len = u64_of(read(8, &mut reader)?) as usize;
                        read(len, &mut reader)?;
                    } else {
                        read(scalar_size(inner).ok_or_else(bad)?, &mut reader)?;
                    }
                }
            }
            kind => {
                let size = scalar_size(kind).ok_or_else(bad)?;
                let bytes = read(size, &mut reader)?;
                if wanted {
                    let value = match kind {
                        4 => u32_of(bytes) as u64,
                        5 => u32_of(bytes) as i32 as u64,
                        10 | 11 => u64_of(bytes),
                        _ => continue,
                    };
                    found.insert(key, value.to_string());
                }
            }
        }
        if found.len() == keys.len() {
            break;
        }
    }
    Ok(found)
}

/// Swap the two axes of a matrix.
fn transpose(tensor: Tensor) -> Tensor {
    let (rows, cols) = (tensor.shape[0], tensor.shape[1]);
    let mut data = vec![0f32; tensor.data.len()];
    for row in 0..rows {
        for col in 0..cols {
            data[col * rows + row] = tensor.data[row * cols + col];
        }
    }
    Tensor {
        shape: vec![cols, rows],
        data,
    }
}

#[derive(Deserialize)]
struct SafetensorsEntry {
    dtype: String,
    shape: Vec<usize>,
    data_offsets: [usize; 2],
}

/// A safetensors file: an 8-byte header length, a JSON header, then data.
fn read_safetensors(path: &Path) -> Result<BTreeMap<String, Tensor>, ImportError> {
    let bytes = std::fs::read(path).map_err(|err| fail(format!("{}: {err}", path.display())))?;
    let header_len = bytes
        .get(..8)
        .map(|raw| u64::from_le_bytes(raw.try_into().unwrap_or_default()) as usize)
        .ok_or_else(|| fail("the adapter file is truncated"))?;
    let header = bytes
        .get(8..8 + header_len)
        .ok_or_else(|| fail("the adapter file's header is truncated"))?;
    let mut entries: BTreeMap<String, serde_json::Value> =
        serde_json::from_slice(header).map_err(|err| fail(format!("adapter header: {err}")))?;
    entries.remove("__metadata__");
    let data = &bytes[8 + header_len..];

    let mut tensors = BTreeMap::new();
    for (name, value) in entries {
        let entry: SafetensorsEntry =
            serde_json::from_value(value).map_err(|err| fail(format!("`{name}`: {err}")))?;
        if entry.dtype != "F32" {
            return Err(fail(format!(
                "`{name}` is {}; only F32 adapters can be imported so far",
                entry.dtype
            )));
        }
        let [start, end] = entry.data_offsets;
        let raw = data
            .get(start..end)
            .ok_or_else(|| fail(format!("`{name}` points outside the file")))?;
        let count: usize = entry.shape.iter().product();
        if raw.len() != count * 4 {
            return Err(fail(format!("`{name}` has the wrong number of bytes")));
        }
        let values = raw
            .as_chunks::<4>()
            .0
            .iter()
            .map(|chunk| f32::from_le_bytes(*chunk))
            .collect();
        tensors.insert(
            name,
            Tensor {
                shape: entry.shape,
                data: values,
            },
        );
    }
    Ok(tensors)
}

const GGUF_ALIGNMENT: u64 = 32;
const GGUF_STRING: u32 = 8;
const GGUF_F32_VALUE: u32 = 6;
const GGML_TYPE_F32: u32 = 0;

fn gguf_string(out: &mut Vec<u8>, value: &str) {
    out.extend_from_slice(&(value.len() as u64).to_le_bytes());
    out.extend_from_slice(value.as_bytes());
}

fn padding(length: u64) -> u64 {
    (GGUF_ALIGNMENT - length % GGUF_ALIGNMENT) % GGUF_ALIGNMENT
}

/// GGUF version 3: header, metadata, tensor descriptions, then aligned data.
fn write_gguf(
    out: &Path,
    architecture: &str,
    alpha: f32,
    tensors: &BTreeMap<String, Tensor>,
) -> Result<(), ImportError> {
    let mut head = Vec::new();
    head.extend_from_slice(b"GGUF");
    head.extend_from_slice(&3u32.to_le_bytes());
    head.extend_from_slice(&(tensors.len() as u64).to_le_bytes());
    let strings = [
        ("general.architecture", architecture),
        ("general.type", "adapter"),
        ("adapter.type", "lora"),
    ];
    head.extend_from_slice(&(strings.len() as u64 + 1).to_le_bytes());
    for (key, value) in strings {
        gguf_string(&mut head, key);
        head.extend_from_slice(&GGUF_STRING.to_le_bytes());
        gguf_string(&mut head, value);
    }
    gguf_string(&mut head, "adapter.lora.alpha");
    head.extend_from_slice(&GGUF_F32_VALUE.to_le_bytes());
    head.extend_from_slice(&alpha.to_le_bytes());

    let mut offset = 0u64;
    for (name, tensor) in tensors {
        gguf_string(&mut head, name);
        head.extend_from_slice(&(tensor.shape.len() as u32).to_le_bytes());
        // ggml lists the fastest-moving axis first.
        for dim in tensor.shape.iter().rev() {
            head.extend_from_slice(&(*dim as u64).to_le_bytes());
        }
        head.extend_from_slice(&GGML_TYPE_F32.to_le_bytes());
        head.extend_from_slice(&offset.to_le_bytes());
        let bytes = tensor.data.len() as u64 * 4;
        offset += bytes + padding(bytes);
    }
    head.resize(head.len() + padding(head.len() as u64) as usize, 0);

    let staging = out.with_extension("gguf.part");
    let write = || -> std::io::Result<()> {
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut file = std::io::BufWriter::new(std::fs::File::create(&staging)?);
        file.write_all(&head)?;
        for tensor in tensors.values() {
            for value in &tensor.data {
                file.write_all(&value.to_le_bytes())?;
            }
            let bytes = tensor.data.len() as u64 * 4;
            file.write_all(&vec![0u8; padding(bytes) as usize])?;
        }
        file.flush()?;
        drop(file);
        std::fs::rename(&staging, out)
    };
    write().map_err(|err| fail(format!("{}: {err}", out.display())))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A two-layer synthetic gpt-oss adapter: rank 2, one attention matrix
    /// and one expert matrix per layer, with values that reveal transposition.
    fn synthetic(dir: &Path, extra: Option<&str>) {
        std::fs::create_dir_all(dir).unwrap();
        std::fs::write(
            dir.join("adapter_config.json"),
            r#"{"fine_tune_type":"lora","model":"mlx-community/gpt-oss-20b-MXFP4-Q8",
               "lora_parameters":{"rank":2,"alpha":4,"dropout":0.0,"scale":10.0}}"#,
        )
        .unwrap();
        let mut tensors: Vec<(String, Vec<usize>, Vec<f32>)> = Vec::new();
        for layer in [3, 5] {
            // q_proj: in 3, out 4.
            tensors.push((
                format!("model.layers.{layer}.self_attn.q_proj.lora_a"),
                vec![3, 2],
                (0..6).map(|v| v as f32).collect(),
            ));
            tensors.push((
                format!("model.layers.{layer}.self_attn.q_proj.lora_b"),
                vec![2, 4],
                (0..8).map(|v| v as f32).collect(),
            ));
            // two experts, in 3, out 3.
            tensors.push((
                format!("model.layers.{layer}.mlp.experts.up_proj.lora_a"),
                vec![2, 2, 3],
                (0..12).map(|v| v as f32).collect(),
            ));
            tensors.push((
                format!("model.layers.{layer}.mlp.experts.up_proj.lora_b"),
                vec![2, 3, 2],
                (0..12).map(|v| v as f32).collect(),
            ));
        }
        if let Some(name) = extra {
            tensors.push((name.into(), vec![3, 2], vec![0.0; 6]));
        }
        let mut header = serde_json::Map::new();
        let mut data = Vec::new();
        for (name, shape, values) in &tensors {
            let start = data.len();
            for value in values {
                data.extend_from_slice(&value.to_le_bytes());
            }
            header.insert(
                name.clone(),
                serde_json::json!({"dtype":"F32","shape":shape,"data_offsets":[start, data.len()]}),
            );
        }
        let header = serde_json::to_vec(&header).unwrap();
        let mut file = (header.len() as u64).to_le_bytes().to_vec();
        file.extend_from_slice(&header);
        file.extend_from_slice(&data);
        std::fs::write(dir.join("adapters.safetensors"), file).unwrap();
    }

    /// Enough of a GGUF reader to check what was written: metadata strings
    /// and floats, and each tensor's ggml shape and values.
    #[allow(clippy::type_complexity)]
    fn read_gguf(
        path: &Path,
    ) -> (
        BTreeMap<String, String>,
        f32,
        BTreeMap<String, (Vec<u64>, Vec<f32>)>,
    ) {
        let bytes = std::fs::read(path).unwrap();
        let mut at = 0usize;
        let mut take = |n: usize| {
            let slice = &bytes[at..at + n];
            at += n;
            slice.to_vec()
        };
        assert_eq!(take(4), b"GGUF");
        assert_eq!(u32::from_le_bytes(take(4).try_into().unwrap()), 3);
        let tensor_count = u64::from_le_bytes(take(8).try_into().unwrap());
        let kv_count = u64::from_le_bytes(take(8).try_into().unwrap());
        let string = |take: &mut dyn FnMut(usize) -> Vec<u8>| {
            let len = u64::from_le_bytes(take(8).try_into().unwrap()) as usize;
            String::from_utf8(take(len)).unwrap()
        };
        let mut strings = BTreeMap::new();
        let mut alpha = 0.0;
        for _ in 0..kv_count {
            let key = string(&mut take);
            match u32::from_le_bytes(take(4).try_into().unwrap()) {
                GGUF_STRING => {
                    let value = string(&mut take);
                    strings.insert(key, value);
                }
                GGUF_F32_VALUE => alpha = f32::from_le_bytes(take(4).try_into().unwrap()),
                other => panic!("unexpected metadata type {other}"),
            }
        }
        let mut infos = Vec::new();
        for _ in 0..tensor_count {
            let name = string(&mut take);
            let dims = u32::from_le_bytes(take(4).try_into().unwrap());
            let shape: Vec<u64> = (0..dims)
                .map(|_| u64::from_le_bytes(take(8).try_into().unwrap()))
                .collect();
            assert_eq!(
                u32::from_le_bytes(take(4).try_into().unwrap()),
                GGML_TYPE_F32
            );
            let offset = u64::from_le_bytes(take(8).try_into().unwrap());
            infos.push((name, shape, offset));
        }
        drop(take);
        let data_start = at + padding(at as u64) as usize;
        let tensors = infos
            .into_iter()
            .map(|(name, shape, offset)| {
                let count: u64 = shape.iter().product();
                let start = data_start + offset as usize;
                let values = bytes[start..start + count as usize * 4]
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|c| f32::from_le_bytes(*c))
                    .collect();
                (name, (shape, values))
            })
            .collect();
        (strings, alpha, tensors)
    }

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("farhelm-import-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn an_mlx_adapter_becomes_a_llama_cpp_adapter() {
        let dir = scratch("ok");
        synthetic(&dir, None);
        let out = dir.join("c2.gguf");
        let imported = import_mlx_lora(&dir, "gpt-oss", None, &out).unwrap();
        assert_eq!(imported.rank, 2);
        assert_eq!(imported.alpha, 20.0, "alpha / rank must equal MLX's scale");
        assert_eq!(imported.tensors, 8);
        assert_eq!(imported.layers, [3, 5]);

        let (strings, alpha, tensors) = read_gguf(&out);
        assert_eq!(strings["general.architecture"], "gpt-oss");
        assert_eq!(strings["general.type"], "adapter");
        assert_eq!(strings["adapter.type"], "lora");
        assert_eq!(alpha, 20.0);

        // A linear lora_a (in 3, r 2) is transposed to numpy (2, 3), which
        // ggml lists as [3, 2]; row 0 of the result is column 0 of the input.
        let (shape, values) = &tensors["blk.3.attn_q.weight.lora_a"];
        assert_eq!(shape, &[3, 2]);
        assert_eq!(values, &[0.0, 2.0, 4.0, 1.0, 3.0, 5.0]);
        let (shape, _) = &tensors["blk.3.attn_q.weight.lora_b"];
        assert_eq!(shape, &[2, 4]);

        // Expert matrices keep their layout; ggml lists the expert axis last.
        let (shape, values) = &tensors["blk.5.ffn_up_exps.weight.lora_a"];
        assert_eq!(shape, &[3, 2, 2]);
        assert_eq!(values[..3], [0.0, 1.0, 2.0]);
        let (shape, _) = &tensors["blk.5.ffn_up_exps.weight.lora_b"];
        assert_eq!(shape, &[2, 3, 2]);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn qwen35_value_heads_move_to_the_gguf_order() {
        // Two key heads, four value heads of two values each: MLX order is
        // v0 v1 | v2 v3 (grouped by key head), GGUF order v0 v2 v1 v3.
        let layout = ValueHeads {
            key_heads: 2,
            value_heads: 4,
            key_dim: 1,
            value_dim: 2,
        };
        assert_eq!(
            (0..4).map(|i| layout.source(i)).collect::<Vec<_>>(),
            [0, 2, 1, 3]
        );

        // attn_gate lora_b: (8 outputs, rank 1), row r holds value r.
        let gate = Tensor {
            shape: vec![8, 1],
            data: (0..8).map(|v| v as f32).collect(),
        };
        let moved = layout.reorder("attn_gate", "lora_b", gate, "gate").unwrap();
        assert_eq!(moved.data, [0.0, 1.0, 4.0, 5.0, 2.0, 3.0, 6.0, 7.0]);

        // attn_qkv lora_b: q and k (two key heads each, four rows) stay; the
        // value block moves.
        let qkv = Tensor {
            shape: vec![12, 1],
            data: (0..12).map(|v| v as f32).collect(),
        };
        let moved = layout.reorder("attn_qkv", "lora_b", qkv, "qkv").unwrap();
        assert_eq!(
            moved.data,
            [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 8.0, 9.0, 6.0, 7.0, 10.0, 11.0]
        );

        // ssm_out lora_a: (rank 1, 8 inputs); the inputs move.
        let out = Tensor {
            shape: vec![1, 8],
            data: (0..8).map(|v| v as f32).collect(),
        };
        let moved = layout.reorder("ssm_out", "lora_a", out, "out").unwrap();
        assert_eq!(moved.data, [0.0, 1.0, 4.0, 5.0, 2.0, 3.0, 6.0, 7.0]);

        // Untouched: the MLP, and the other half of each pair.
        let ffn = Tensor {
            shape: vec![2, 3],
            data: vec![1.0; 6],
        };
        assert_eq!(
            layout.reorder("ffn_up", "lora_b", ffn, "ffn").unwrap().data,
            vec![1.0; 6]
        );

        // A shape that does not fit the layout is refused.
        let wrong = Tensor {
            shape: vec![6, 1],
            data: vec![0.0; 6],
        };
        assert!(
            layout
                .reorder("attn_gate", "lora_b", wrong, "gate")
                .is_err()
        );
    }

    #[test]
    fn the_head_layout_is_read_from_the_base_models_header() {
        let dir = scratch("base");
        std::fs::create_dir_all(&dir).unwrap();
        let mut file = b"GGUF".to_vec();
        file.extend_from_slice(&3u32.to_le_bytes());
        file.extend_from_slice(&0u64.to_le_bytes());
        file.extend_from_slice(&7u64.to_le_bytes());
        let string_kv = |file: &mut Vec<u8>, key: &str, value: &str| {
            gguf_string(file, key);
            file.extend_from_slice(&8u32.to_le_bytes());
            gguf_string(file, value);
        };
        string_kv(&mut file, "general.architecture", "qwen35");
        // An array to skip, as a tokenizer vocabulary would be.
        gguf_string(&mut file, "tokenizer.ggml.tokens");
        file.extend_from_slice(&9u32.to_le_bytes());
        file.extend_from_slice(&8u32.to_le_bytes());
        file.extend_from_slice(&2u64.to_le_bytes());
        gguf_string(&mut file, "a");
        gguf_string(&mut file, "bc");
        for (key, value) in [
            ("qwen35.ssm.group_count", 16u32),
            ("qwen35.ssm.time_step_rank", 32),
            ("qwen35.ssm.inner_size", 4096),
            ("qwen35.ssm.state_size", 128),
        ] {
            gguf_string(&mut file, key);
            file.extend_from_slice(&4u32.to_le_bytes());
            file.extend_from_slice(&value.to_le_bytes());
        }
        let base = dir.join("base.gguf");
        std::fs::write(&base, file).unwrap();
        assert_eq!(
            ValueHeads::from_base(&base).unwrap(),
            ValueHeads {
                key_heads: 16,
                value_heads: 32,
                key_dim: 128,
                value_dim: 128
            }
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn an_unknown_tensor_is_refused_rather_than_dropped() {
        let dir = scratch("unknown");
        synthetic(&dir, Some("model.layers.3.self_attn.sinks.lora_a"));
        let err = import_mlx_lora(&dir, "gpt-oss", None, &dir.join("out.gguf")).unwrap_err();
        assert!(err.0.contains("no counterpart"), "{err}");
        assert!(!dir.join("out.gguf").exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn an_unsupported_architecture_says_which_are() {
        let dir = scratch("arch");
        synthetic(&dir, None);
        let err = import_mlx_lora(&dir, "llama", None, &dir.join("out.gguf")).unwrap_err();
        assert!(err.0.contains("gpt-oss and qwen35 are"), "{err}");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}

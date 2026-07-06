# 模块 02：GPU 软件栈

> CUDA Toolkit、cuDNN、NCCL 的安装、版本对齐、验证。

---

## 版本兼容规则

```
规则 1：驱动决定一切
  驱动 550 最高支持 CUDA 12.4
  不能在这个驱动上运行 CUDA 12.6 编译的程序

规则 2：CUDA Toolkit 不是运行必需
  PyTorch pip install 自带 CUDA 运行时
  只有需要 nvcc 编译时才需要系统 CUDA Toolkit

规则 3：cuDNN 版本由 CUDA 版本决定
  cuDNN 8.9.x → CUDA 11.x 或 12.x
  cuDNN 9.x   → CUDA 12.x

规则 4：NCCL 版本建议匹配 CUDA
  CUDA 12.x → NCCL 2.19+
```

---

## 版本检查命令

```bash
# 驱动
nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1

# 驱动支持的 CUDA 上限
nvidia-smi | grep "CUDA Version"

# 系统 CUDA Toolkit
nvcc --version | grep release

# PyTorch 自带 CUDA
python3 -c "import torch; print(torch.version.cuda)"

# cuDNN
python3 -c "import torch; print(torch.backends.cudnn.version())"

# NCCL
python3 -c "import torch; print(torch.cuda.nccl.version())"
```

---

## CUDA 两层 API

```
libcudart.so (Runtime API)  ← 程序常用，cudaMalloc 等
    ↓ 内部调用
libcuda.so (Driver API)     ← 驱动自带，cuInit 等
    ↓ ioctl
nvidia.ko → GPU
```

---

## 安装指南

```bash
# CUDA Toolkit (apt)
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update
sudo apt install -y cuda-toolkit-12-4
echo 'export PATH=/usr/local/cuda/bin:$PATH' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc

# PyTorch (国内镜像)
pip3 install torch torchvision torchaudio -i https://pypi.tuna.tsinghua.edu.cn/simple

# NCCL
pip3 install nvidia-nccl-cu12 -i https://pypi.tuna.tsinghua.edu.cn/simple

# cuDNN (手动 tar 包安装)
tar -xf cudnn-linux-x86_64-8.9.7.29_cuda12-archive.tar.xz
sudo cp include/cudnn*.h /usr/local/cuda/include/
sudo cp lib/libcudnn* /usr/local/cuda/lib64/
sudo chmod a+r /usr/local/cuda/lib64/libcudnn*
```

---

## 验证全栈正常

```bash
# 最小 CUDA 程序验证
cat > /tmp/hello.cu << 'EOF'
#include <stdio.h>
#include <cuda_runtime.h>
__global__ void hello() {
    printf("GPU says hello! (block %d, thread %d)\n", blockIdx.x, threadIdx.x);
}
int main() {
    int count;
    cudaGetDeviceCount(&count);
    printf("Found %d GPU(s)\n", count);
    hello<<<2, 4>>>();
    cudaDeviceSynchronize();
    return 0;
}
EOF
nvcc -o /tmp/hello /tmp/hello.cu && /tmp/hello
```

```bash
# PyTorch 验证
python3 -c "
import torch
print(f'PyTorch: {torch.__version__}')
print(f'GPU: {torch.cuda.is_available()}')
a = torch.randn(1000, 1000).cuda()
b = torch.randn(1000, 1000).cuda()
c = torch.mm(a, b)
print(f'GPU compute: OK, result shape {c.shape}')
"
```

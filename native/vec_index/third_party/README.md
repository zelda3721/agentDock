# vec_index / third_party

**本次（骨架搭建）不拉取任何子模块**——拉取与交叉编译由 **T0.9-11**（vec_index：hnswlib 交叉编译 NAPI）执行。
在子模块缺席的情况下，`src/main/cpp/CMakeLists.txt` 的 `if(EXISTS ...)` 守卫会跳过 `add_subdirectory`，
本模块仍可 configure + 编译出 `libvec_index.so`（所有 NAPI 入口返回 `NOT_IMPLEMENTED(2099)`）。

## 待引入的依赖

| 目录 | 上游仓库 | 锁定方式 | 许可证 | 兼容性 |
|---|---|---|---|---|
| `third_party/hnswlib` | https://github.com/nmslib/hnswlib | git submodule，**锁定 release tag**（tag 由 T0.9-11 选定并写回本表） | **Apache-2.0** | ✅ 与本项目 Apache-2.0 同许可（§22.2） |

义务要点（§22.2）：保留 NOTICE、声明修改；许可原文复制到仓库根 `THIRD_PARTY_LICENSES/hnswlib.LICENSE`。

**hnswlib 是 header-only**：不产出独立 .so，头文件直接编进 `libvec_index.so`。CMake 优先走上游
`CMakeLists.txt`（INTERFACE 目标），并保留 header-only 兜底分支（直接 `include_directories`）。

## 拉取方式（T0.9-11 执行，此处仅备忘）

```bash
git submodule add https://github.com/nmslib/hnswlib native/vec_index/third_party/hnswlib
cd native/vec_index/third_party/hnswlib
git checkout <选定的 release tag>
cd - && git add .gitmodules native/vec_index/third_party/hnswlib
```

## 存储契约（§4.1，实现时不可动摇）

- 每库一个 HNSW 索引文件 + 一个**向量平面文件**（**float16** 存储，省一半空间），与 `kb_chunk.id` 映射。
- **平面文件是唯一真相源，索引是可再生派生物**：写入顺序恒为「先追加平面文件 → 再插 HNSW」。
- **索引损坏可由平面文件全量重建**（`rebuild()`）——这是唯一恢复路径，不得静默降级为空索引。

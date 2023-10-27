# unxip

unxip is a command-line tool designed for rapidly unarchiving Xcode XIP files and writing them to disk with good compression. Its goal is to outperform Bom (which powers `xip(1)` and Archive Utility) in both performance and on-disk usage, and (at the time of writing) does so by a factor of about 2-3x in time spent decompressing and about 25% in space.

## Installation

The easiest way to install unxip is to grab a precompiled binary for macOS 12.0 and later from the [releases page](https://github.com/saagarjha/unxip/releases/latest). If you prefer, you can also install unxip from your package manager: it's [available on MacPorts](https://ports.macports.org/port/unxip/), [and Homebrew](https://formulae.brew.sh/formula/unxip). Both will make the latest version of the command available under the package name "unxip".

## Building

unxip is fairly simple and implemented as a [single file](./unxip.swift). Thus, you can build it by compiling that file directly, with just an up-to-date version of the Command Line Tools (`xcode-select --install`):

```console
$ swiftc -parse-as-library -O unxip.swift
```

This will build an optimized unxip binary for your computer's native architecture. Because unxip uses Swift Concurrency, it is recommended that you build on macOS Monterey or later; macOS Big Sur is technically supported but needs to use backdeployment libraries that are not very easy to distribute with a command line tool.

If you prefer to use Swift Package Manager to build your code, a Package.swift is also available. This has the downside of requiring a full Xcode installation to bootstrap the build, but makes it easy to build a Universal binary:

```console
$ swift build -c release --arch arm64 --arch x86_64
```

When run from the project root, the resulting executable will be located at .build/apple/Products/Release/unxip.

Finally, you may also use the provided Makefile to build and install unxip:

```console
$ make all
$ make install
```

The installation prefix is configurable via the `PREFIX` variable.

unxip is not currently designed to be embedded directly into the address space of another application. While it would "work" (with minor modifications to allow linking) its implementation expects to be the only user of the cooperative thread pool and effectively takes it over, which may adversely affect other code that wishes to run on it. The recommended way to use unxip is spawning it as a subtask.

## Usage

The intended usage of unxip is with a single command line parameter that represents the path to an XIP from Apple that contains Xcode. For example:

```console
$ unxip Xcode.xip # will produce Xcode.app in the current directory
$ curl https://webserver/Xcode.xip | unxip - /Applications # Read from a stream and extract to /Applications
```

As the tool is still somewhat rough, its error handling is not very good at the moment. An attempt has been made to at least crash preemptively when things go wrong, but you may still run into strange behavior on edge cases. For best results, ensure that the directory you are running unxip from does not contain any existing Xcode(-beta).app bundles and that you are using a modern version of macOS on a fast APFS filesystem.

> **Warning**  
> For simplicity, unxip does not perform any signature verification, so if authentication is important you should use another mechanism (such as a checksum) for validation. Consider downloading XIPs only from sources you trust, such as directly from Apple.

## libunxip

While the unxip command-line tool provides a versatile set of functionality to suit most needs, for specialized usecases the internals of unxip are available via a Swift stream-based interface called libunxip. At its core, it provides views into the following streams (for discussion of why these were chosen, see the [Design](#Design) section below):

* A stream of data that represents a raw XIP file, perhaps read from disk or the network
* A stream of decompressed `Chunk`s, which linearly reassemble into a CPIO archive
* A stream of `File`s carved out of the CPIO
* A stream of completions as each `File` is written to disk

In addition to providing some utility functions to read files and handle asynchronous iteration, libunxip handles the hard part of transforming one stream to another, and provides you with an `AsyncSequence` that you can inspect, consume, or pass back to another step in the pipeline. For example, this code counts how many directories are in a XIP file read from standard in and skips writing to disk:

```swift
import libunxip

let data = DataReader(descriptor: STDIN_FILENO)
var directories = 0
for try await file in Unxip.makeStream(from: .xip(input: data), to: .files, input: data) where file.type == .directory {
	directories += 1
}
print("This XIP contains \(directories) directories")
```

For an example of more advanced usage, unxip itself is implemented using libunxip's APIs and can serve as a starting point for your own code.

> **Important**  
> libunxip can produce data *very* quickly, especially when working with intermediate streams of uncompressed data. The internal buffers backing the library have heavy backpressure applied to them to avoid overloading slower consumers. Nevertheless, irresponsible usage (such as wrapping the data in your own sequence or holding on to objects) can very easily lead to data piling up in memory at multiple GB/s. For best results, keep your processing short and copy out just data you require rather than persisting a whole `Chunk` or `File` you don't need. When splitting streams, use the lockstep APIs provided, which will ensure that one side doesn't run ahead of and overwhelm the other.

## Contributing

When making changes, be sure to use [swift-format](https://github.com/apple/swift-format) on the source:

```console
$ swift-format -i *.swift
```

## Design

As a purpose-built tool, unxip outperforms Bom because of several key implementation decisions. Heavy use of [Swift Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html) allows unxip to unlock parallelization opportunities that Bom largely misses, and the use of [LZFSE](https://en.wikipedia.org/wiki/LZFSE) rather than the simpler LZVN gives it higher compression ratios. To understand its design, it's important to first be familiar with the Xcode XIP format and APFS transparent compression.

XIPs, including the ones that Xcode come in, are [XAR archives](https://en.wikipedia.org/wiki/Xar_%28archiver%29), which contain a table of contents that lists each file inside and the compression used for each. However, unlike most XARs Xcode's only has two files: a [bzip2](https://en.wikipedia.org/wiki/Bzip2)-compressed Metadata that is just a few hundred bytes, and a multi-gigabyte file named Content that is stored "uncompressed". While marked as plain data, this file is ~~an apparently proprietary archive format called pbzx. Luckily, the scheme is fairly straightforward and [several](https://gist.github.com/pudquick/ff412bcb29c9c1fa4b8d) [people](https://github.com/nrosenstein-stuff/pbzx) [on the](http://newosxbook.com/src.jl?tree=listings&file=pbzx.c) [internet](https://www.tonymacx86.com/threads/pbzx-stream-parser.135458/) have already tried reverse engineering it. This tool contains an independent implementation that nonetheless shares many of its core details with these efforts.~~ compressed in a format documented by `compression_tool(1)`. The compressed content inside the pbzx is an ASCII-representation [cpio](https://en.wikipedia.org/wiki/cpio) archive, which has been split apart into 16MB chunks that have either been individually compressed with [LZMA](https://en.wikipedia.org/wiki/Lempel–Ziv–Markov_chain_algorithm) or included as-is. Unfortunately pbzx does not contain a table of contents, or any structure aside from these (byte-, rather than file-aligned) chunks, so distinguishing individual files is not possible without decompressing the entire buffer.

Parsing this cpio archive gives the necessary information need to reconstruct an Xcode bundle, but unxip (and Bom) go through an additional step to apply [transparent APFS compression](https://en.wikipedia.org/wiki/Apple_File_System#Compression) to files that could benefit from it, which significantly reduces size on-disk. For this operation, unxip chooses to use the LZFSE algorithm, while Bom uses the simpler LZVN. The compressed data is stored in the file's resource fork, a special header describing the compression is constructed in an xattr, and then `UF_COMPRESSED` is set on the file.

On the whole, this procedure is designed to be fairly linear, with the XIP being read sequentially, producing LZMA chunks that are reassembled in order to create the cpio archive, which can then be streamed to reconstruct an Xcode bundle. Unfortunately, a naive implementation of this is process does not perform very well due to the varying performance bottlenecks of each step. To make matters worse, the size of Xcode makes it infeasible to operate with entirely in memory. To get around this problem, unxip parallelizes *intermediate* steps and then streams results in linear order, benefiting from much better processor utilization and allowing the file to be processed in "sliding window" fashion.

On modern processors, single-threaded LZMA decoding is limited to about ~100 Mb/s; as the Xcode 15 cpio over 10 GB (and the Xcode 13 almost 40!), this is not really fast enough for unxip. Instead, unxip carves out each chunk from the pbzx archive into its own task (the metadata in the file format makes this fairly straightforward) and decompresses each in parallel. To limit memory usage, a cap is applied to how many chunks are resident in memory at once. Since the next step (parsing the cpio) requires logical linearity, completing chunks are temporarily parked until their preceding ones complete, after which they are all yielded together. This preserves order while still providing an opportunity for multiple chunks to be decoded in parallel. In practice, this technique can decode the LZMA stream at effective speeds beyond 1 Gb/s when provided with enough CPU cores.

The linear chunk stream (now decompressed into a cpio) is then parsed in sequence to extract files, directories, and their associated metadata. cpios are naturally ordered–for example, all additional hardlinks must come after the original file–but Xcode's has an additional nice property that it's been sorted so that all directories appear before the files inside of them. This allows for a sequential stream of filesystem operations to correctly produce the bundle, without running into errors with missing intermediate directories or link targets.

While simplifying the implementation, this order makes it difficult for unxip to efficiently schedule filesystem operations and transparent compression. To resolve this, a dependency graph is created for each file (directories, files, and symlinks depend on their parent directory's existence, hardlinks require their target to exist) and then the task is scheduled in parallel with those constraints applied. New file writes are particularly expensive because compression is applied before the data is written to disk. While this step is already parallelized to some extent because of the graph described earlier, there is a chance for additional parallelism in Apple's filesystem compression implementation because it chunks data internally at 64KB chunk boundaries, which we can then run in parallel. LZFSE achieves high compression ratios and has a performant implementation, which we can take advantage of largely for free. Unlike most of our steps, which were compute-bound, the final step of writing to disk requires interacting with the kernel. If we're careless we can accidentally overload the system with operations and back up our entire pipeline. To prevent unconsumed chunks sitting around in memory, we manually apply backpressure on our stream by having them only yield results when later steps are ready to consume them.

Overall, this architecture allows unxip to utilize CPU cores and dispatch disk writes fairly well. It is likely that there is still some room for improvement in its implementation, especially around the constants chosen for batch sizes and backoff intervals (some of which can probably be done much better by the runtime itself [once it is ready](https://github.com/apple/swift/pull/41192)). Ideas on how its performance can be further improved are always welcome :)

Finally, I am very thankful to Kevin Elliott and the rest of the DTS team for fielding some of my filesystem-related questions; the answers were very helpful when I was designing unxip.

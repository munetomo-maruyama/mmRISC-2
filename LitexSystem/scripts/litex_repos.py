#!/usr/bin/env python3
#
# litex_repos.py : the LiteX repositories at the commits mmRISC-2 is built with
#
# Written by `litex_setup.py --freeze` from the workspace used for the board
# (LitexRocket/litex_ws, 2026-09). scripts/setup_litex.sh clones every
# repository below at its sha1 and installs them; litex_setup.py reads this
# file in place of the latest definitions of LiteX.

# Git repositories ---------------------------------------------------------------------------------

# Get SHA1: git rev-parse HEAD

class GitRepo:
    def __init__(self, url, clone="regular", develop=True, editable=True, sha1=None, branch="master",
        tag=None):
        assert clone in ["regular", "recursive"]
        self.url      = url
        self.clone    = clone
        self.develop  = develop
        self.editable = editable
        self.sha1     = sha1
        self.branch   = branch
        self.tag      = tag


git_repos = {
    "migen": GitRepo(url="https://git.m-labs.hk/M-Labs/", clone="recursive", editable=False, sha1="4c2ae8dfeea37f235b52acb8166f12acaaae4f7c"),
    "pythondata-software-picolibc": GitRepo(url="https://github.com/litex-hub/", clone="recursive", sha1="6a13ccce7c575b32c102dd9dc52178505b81fe39"),
    "pythondata-software-compiler_rt": GitRepo(url="https://github.com/litex-hub/", sha1="6eb76609c9627bf26635e57c63fb22cda7115887"),
    "litex": GitRepo(url="https://github.com/enjoy-digital/", sha1="6d8a38cade2092cb1e7db3e5602e81093aead8f9", tag=True),
    "liteiclink": GitRepo(url="https://github.com/enjoy-digital/", sha1="8a4ce305510614266dad462dbe6b1f154f7487f4", tag=True),
    "liteeth": GitRepo(url="https://github.com/enjoy-digital/", sha1="8c9150ff121cb3148d8ea26ce3b1c5200479848d", tag=True),
    "litedram": GitRepo(url="https://github.com/enjoy-digital/", sha1="ab27325fa488ada7a0e1cef271e5bd7d94c2bb7e", tag=True),
    "litepcie": GitRepo(url="https://github.com/enjoy-digital/", sha1="c4ac65f3340f7ded11470ebec165ae06c563def6", tag=True),
    "litesata": GitRepo(url="https://github.com/enjoy-digital/", sha1="d3d2b92f634730b05005cc565a10b43289b411e7", tag=True),
    "litesdcard": GitRepo(url="https://github.com/enjoy-digital/", sha1="227d61bc2b92ca56cac78a539b98e378468b1ba1", tag=True),
    "litescope": GitRepo(url="https://github.com/enjoy-digital/", sha1="6bf3b92f261c50b8c7c74947f84e692ae846f512", tag=True),
    "litedsp": GitRepo(url="https://github.com/enjoy-digital/", sha1="4ff1ea2bafd12452e59bf456bc4668d07bbb6b01", branch="main"),
    "litespi": GitRepo(url="https://github.com/litex-hub/", sha1="2e211447af44d9f015fd1c50c5b10d399b640972", tag=True),
    "litei2c": GitRepo(url="https://github.com/litex-hub/", sha1="81cf75d3e6fc8ddfe4dece68cd7e2b39a2a4385e", branch="main", tag=True),
    "litex-boards": GitRepo(url="https://github.com/litex-hub/", sha1="bca0201f1f22de6789a30ff809367cf16ab6a0bc", tag=True),
    "pythondata-misc-tapcfg": GitRepo(url="https://github.com/litex-hub/", sha1="a12c3f592c99f9c082fdc68c065b81cbd6e6b238"),
    "pythondata-misc-usb_ohci": GitRepo(url="https://github.com/litex-hub/", clone="recursive", sha1="17c1d3d6548ea267e19aec3cb6d2e64335a1bb2a"),
    "pythondata-cpu-lm32": GitRepo(url="https://github.com/litex-hub/", sha1="0f1d1b91202b95a9b749a745848430d64afb4400"),
    "pythondata-cpu-mor1kx": GitRepo(url="https://github.com/litex-hub/", sha1="ba6ea16dc1250ac138ea0d923af4f91da790892f"),
    "pythondata-cpu-marocchino": GitRepo(url="https://github.com/litex-hub/", sha1="1e7ffe1b337e9280aaa77cdc763685b2b12124c2"),
    "pythondata-cpu-microwatt": GitRepo(url="https://github.com/litex-hub/", sha1="c69953aff92da0a2696877884a009c3718cfaa51"),
    "pythondata-cpu-cdim": GitRepo(url="https://github.com/litex-hub/", sha1="46f328e00bb51c050973ed433d5b687877d1838b", branch="main"),
    "pythondata-cpu-gs232": GitRepo(url="https://github.com/litex-hub/", sha1="3c21af565d37292321b58dff5c621315f7c7f06b", branch="main"),
    "pythondata-cpu-blackparrot": GitRepo(url="https://github.com/litex-hub/", sha1="3d97ebaaecba8f67788dbd2c7d6f8cc5d031ff15"),
    "pythondata-cpu-coreblocks": GitRepo(url="https://github.com/litex-hub/", clone="recursive", sha1="9facb7af5fd20265d31a2a7c4ff2b4ea1ad8cdb4"),
    "pythondata-cpu-cv32e40p": GitRepo(url="https://github.com/litex-hub/", clone="recursive", sha1="19f8654021760e361a0b0c0178347ff6f3bed193"),
    "pythondata-cpu-cv32e41p": GitRepo(url="https://github.com/litex-hub/", clone="recursive", sha1="ffb39a9a2a07eb4279675d037b092bf943cae2c2"),
    "pythondata-cpu-cva5": GitRepo(url="https://github.com/litex-hub/", sha1="df23fb0ab7295f5ffce7f430f92390f2106f9ea7"),
    "pythondata-cpu-cva6": GitRepo(url="https://github.com/litex-hub/", clone="recursive", sha1="da8c19c8142eee4053b714fc2b748d746e17f175"),
    "pythondata-cpu-ibex": GitRepo(url="https://github.com/litex-hub/", clone="recursive", sha1="5ac251006b93cc34b6366aa6ee238a85b31b9398"),
    "pythondata-cpu-minerva": GitRepo(url="https://github.com/litex-hub/", sha1="ab328774891c70694c6576be19d1d3e427d9f435"),
    "pythondata-cpu-naxriscv": GitRepo(url="https://github.com/litex-hub/", sha1="20da269306bb3bfabd09de08d4c1be1fbc202474"),
    "pythondata-cpu-openc906": GitRepo(url="https://github.com/litex-hub/", sha1="c7c0472fd315875a16bab13d32e30d92a352efda"),
    "pythondata-cpu-picorv32": GitRepo(url="https://github.com/litex-hub/", sha1="f41d93dc42195872548b359d1fbb4594d25d7211"),
    "pythondata-cpu-rocket": GitRepo(url="https://github.com/litex-hub/", sha1="d641037640637471e82646e69a055475cd2abfab"),
    "pythondata-cpu-sentinel": GitRepo(url="https://github.com/litex-hub/", sha1="7ec5e1e5db1a53910e4c58ae4c098ebce3f9591f", branch="main"),
    "pythondata-cpu-serv": GitRepo(url="https://github.com/litex-hub/", sha1="111947d7ab652c28642d7ff0a528dae293ca4601"),
    "pythondata-cpu-veer_eh1": GitRepo(url="https://github.com/litex-hub/", sha1="8d01ede7ea2ff40d4526616b0e2c91de0142508e", branch="main"),
    "pythondata-cpu-vexiiriscv": GitRepo(url="https://github.com/litex-hub/", sha1="15cfab529a17c473d0fc75edf3f409eb374cef35", branch="main"),
    "pythondata-cpu-vexriscv": GitRepo(url="https://github.com/litex-hub/", sha1="642ecfed1c84460555d6d803d660cc60cfc1ecb6"),
    "pythondata-cpu-vexriscv-smp": GitRepo(url="https://github.com/litex-hub/", clone="recursive", sha1="217d23d7e9ad5556c17a73dc6ffc1971765f3d7c"),
}

# Installs -----------------------------------------------------------------------------------------

frozen_repos = ['migen', 'pythondata-software-picolibc', 'pythondata-software-compiler_rt', 'litex', 'liteiclink', 'liteeth', 'litedram', 'litepcie', 'litesata', 'litesdcard', 'litescope', 'litedsp', 'litespi', 'litei2c', 'litex-boards', 'pythondata-misc-tapcfg', 'pythondata-misc-usb_ohci', 'pythondata-cpu-lm32', 'pythondata-cpu-mor1kx', 'pythondata-cpu-marocchino', 'pythondata-cpu-microwatt', 'pythondata-cpu-cdim', 'pythondata-cpu-gs232', 'pythondata-cpu-blackparrot', 'pythondata-cpu-coreblocks', 'pythondata-cpu-cv32e40p', 'pythondata-cpu-cv32e41p', 'pythondata-cpu-cva5', 'pythondata-cpu-cva6', 'pythondata-cpu-ibex', 'pythondata-cpu-minerva', 'pythondata-cpu-naxriscv', 'pythondata-cpu-openc906', 'pythondata-cpu-picorv32', 'pythondata-cpu-rocket', 'pythondata-cpu-sentinel', 'pythondata-cpu-serv', 'pythondata-cpu-veer_eh1', 'pythondata-cpu-vexiiriscv', 'pythondata-cpu-vexriscv', 'pythondata-cpu-vexriscv-smp']

# Reuse the frozen set for every install config.
minimal_repos  = frozen_repos
standard_repos = frozen_repos
full_repos     = frozen_repos

install_configs = {
    "minimal"  : minimal_repos,
    "standard" : standard_repos,
    "full"     : full_repos,
}

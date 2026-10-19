#!/usr/bin/env python3
#---------------------------------------------------------------------------
# eclipse_project.py : the Eclipse files of a bare-metal program
#
#   python3 eclipse_project.py <program directory> ...
#
# Writes, in each directory, the project of Eclipse Embedded CDT (a managed
# build with the "RISC-V Cross GCC" toolchain, as the mmRISC-1 projects were)
# and its two debug configurations:
#
#   .project                      the folder ../common linked in as common/,
#                                 out/ (the Makefile's) left out
#   .cproject                     Debug (-O0) and Release (-O2): rv64imafdc +
#                                 Zicsr / Zifencei / Zba / Zbb / Zbs, lp64d,
#                                 medany, common/link.ld, -nostartfiles, libm
#   <name> Debug JTAG.launch      OpenOCD + gdb over 4-wire JTAG
#   <name> Debug cJTAG.launch     the same over 2-wire cJTAG
#
# The toolchain (riscv-none-elf-, xPack) and OpenOCD are found through
# Eclipse's global paths (Preferences > MCU), so the same files work on
# Ubuntu and on Windows. The Makefile next to them builds the same program
# from the command line. LitexSystem/docs/ECLIPSE.md has the steps.
#---------------------------------------------------------------------------
import os, sys, zlib

R = 'ilg.gnumcueclipse.managedbuild.cross.riscv.'

def uid(*parts):                  # stable ids, so a rerun changes nothing
    return str(zlib.crc32('/'.join(parts).encode()) % 1000000000)

def opt(cfg, name, value=None, vtype=None, items=None, attrs=''):
    i = R + 'option.' + name
    if items is not None:
        s = f'<option IS_BUILTIN_EMPTY="false" IS_VALUE_EMPTY="false" id="{i}.{uid(cfg, name)}" superClass="{i}"{attrs} valueType="{vtype}">\n'
        for v in items:
            s += f'\t\t\t\t\t\t\t\t\t<listOptionValue builtIn="false" value="{v}"/>\n'
        return s + '\t\t\t\t\t\t\t\t</option>'
    return f'<option id="{i}.{uid(cfg, name)}" superClass="{i}"{attrs} value="{value}" valueType="{vtype}"/>'

def cconfig(proj, kind):
    debug = (kind == 'debug')
    cid = f'{R}config.elf.{kind}.{uid(proj, kind)}'
    name = 'Debug' if debug else 'Release'
    olevel = R + 'option.optimization.level.' + ('none' if debug else 'more')
    tc = [
        opt(cid, 'command.prefix', 'riscv-none-elf-', 'string'),
        opt(cid, 'command.c', 'gcc', 'string'),
        opt(cid, 'command.cpp', 'g++', 'string'),
        opt(cid, 'command.ar', 'ar', 'string'),
        opt(cid, 'command.objcopy', 'objcopy', 'string'),
        opt(cid, 'command.objdump', 'objdump', 'string'),
        opt(cid, 'command.size', 'size', 'string'),
        opt(cid, 'command.make', 'make', 'string'),
        opt(cid, 'command.rm', 'rm', 'string'),
        opt(cid, 'toolchain.name', 'xPack GNU RISC-V Embedded GCC', 'string'),
        # the key of the global toolchain path: Java's hashCode() of the name
        opt(cid, 'toolchain.id', '2273142912', 'string'),
        opt(cid, 'target.isa.base', R + 'option.target.arch.rv64i', 'enumerated'),
        opt(cid, 'target.isa.multiply', 'true', 'boolean'),
        opt(cid, 'target.isa.atomic', 'true', 'boolean'),
        opt(cid, 'target.isa.fp', R + 'option.isa.fp.double', 'enumerated'),
        opt(cid, 'target.isa.compressed', 'true', 'boolean'),
        opt(cid, 'target.isa.extensions', '_zicsr_zifencei_zba_zbb_zbs', 'string'),
        opt(cid, 'target.abi.integer', R + 'option.abi.integer.lp64', 'enumerated'),
        opt(cid, 'target.abi.fp', R + 'option.abi.fp.double', 'enumerated'),
        opt(cid, 'target.codemodel', R + 'option.target.codemodel.any', 'enumerated'),
        opt(cid, 'optimization.level', olevel, 'enumerated'),
        opt(cid, 'optimization.functionsections', 'true', 'boolean'),
        opt(cid, 'optimization.datasections', 'true', 'boolean'),
        opt(cid, 'debugging.level', R + 'option.debugging.level.max', 'enumerated'),
        opt(cid, 'addtools.createflash', 'true', 'boolean'),
        opt(cid, 'addtools.createlisting', 'true', 'boolean'),
        opt(cid, 'addtools.printsize', 'true', 'boolean'),
    ]
    inc = '&quot;${ProjDirPath}/../common&quot;'
    script = '&quot;${ProjDirPath}/../common/link.ld&quot;'
    T = '\t' * 8
    tools = f'''
							<tool id="{R}tool.assembler.{uid(cid,'as')}" superClass="{R}tool.assembler">
								{opt(cid, 'assembler.usepreprocessor', 'true', 'boolean')}
								{opt(cid, 'assembler.include.paths', vtype='includePath', items=[inc])}
								<inputType id="{R}tool.assembler.input.{uid(cid,'asi')}" superClass="{R}tool.assembler.input"/>
							</tool>
							<tool id="{R}tool.c.compiler.{uid(cid,'cc')}" superClass="{R}tool.c.compiler">
								{opt(cid, 'c.compiler.include.paths', vtype='includePath', items=[inc])}
								<inputType id="{R}tool.c.compiler.input.{uid(cid,'cci')}" superClass="{R}tool.c.compiler.input"/>
							</tool>
							<tool id="{R}tool.c.linker.{uid(cid,'ld')}" superClass="{R}tool.c.linker">
								{opt(cid, 'c.linker.gcsections', 'true', 'boolean')}
								{opt(cid, 'c.linker.nostart', 'true', 'boolean')}
								{opt(cid, 'c.linker.scriptfile', vtype='stringList', items=[script])}
								{opt(cid, 'c.linker.other', '-Wl,--no-warn-rwx-segments', 'string')}
								{opt(cid, 'c.linker.libs', vtype='libs', items=['m'])}
								<inputType id="{R}tool.c.linker.input.{uid(cid,'ldi')}" superClass="{R}tool.c.linker.input">
									<additionalInput kind="additionalinputdependency" paths="$(USER_OBJS)"/>
									<additionalInput kind="additionalinput" paths="$(LIBS)"/>
								</inputType>
							</tool>
							<tool id="{R}tool.createflash.{uid(cid,'fl')}" superClass="{R}tool.createflash"/>
							<tool id="{R}tool.createlisting.{uid(cid,'li')}" superClass="{R}tool.createlisting">
								{opt(cid, 'createlisting.source', 'true', 'boolean')}
								{opt(cid, 'createlisting.linenumbers', 'true', 'boolean')}
							</tool>
							<tool id="{R}tool.printsize.{uid(cid,'ps')}" superClass="{R}tool.printsize"/>'''
    return f'''		<cconfiguration id="{cid}">
			<storageModule buildSystemId="org.eclipse.cdt.managedbuilder.core.configurationDataProvider" id="{cid}" moduleId="org.eclipse.cdt.core.settings" name="{name}">
				<externalSettings/>
				<extensions>
					<extension id="org.eclipse.cdt.core.ELF" point="org.eclipse.cdt.core.BinaryParser"/>
					<extension id="org.eclipse.cdt.core.GASErrorParser" point="org.eclipse.cdt.core.ErrorParser"/>
					<extension id="org.eclipse.cdt.core.GmakeErrorParser" point="org.eclipse.cdt.core.ErrorParser"/>
					<extension id="org.eclipse.cdt.core.GLDErrorParser" point="org.eclipse.cdt.core.ErrorParser"/>
					<extension id="org.eclipse.cdt.core.CWDLocator" point="org.eclipse.cdt.core.ErrorParser"/>
					<extension id="org.eclipse.cdt.core.GCCErrorParser" point="org.eclipse.cdt.core.ErrorParser"/>
				</extensions>
			</storageModule>
			<storageModule moduleId="cdtBuildSystem" version="4.0.0">
				<configuration artifactName="${{ProjName}}" buildArtefactType="org.eclipse.cdt.build.core.buildArtefactType.exe" buildProperties="org.eclipse.cdt.build.core.buildArtefactType=org.eclipse.cdt.build.core.buildArtefactType.exe,org.eclipse.cdt.build.core.buildType=org.eclipse.cdt.build.core.buildType.{kind}" cleanCommand="${{cross_rm}} -rf" description="" id="{cid}" name="{name}" parent="{R}config.elf.{kind}">
					<folderInfo id="{cid}." name="/" resourcePath="">
						<toolChain id="{R}toolchain.elf.{kind}.{uid(cid,'tc')}" name="RISC-V Cross GCC" superClass="{R}toolchain.elf.{kind}">
{T}{(chr(10)+T).join(tc)}
							<targetPlatform archList="all" binaryParser="org.eclipse.cdt.core.ELF" id="{R}targetPlatform.{uid(cid,'tp')}" isAbstract="false" osList="all" superClass="{R}targetPlatform"/>
							<builder buildPath="${{workspace_loc:/{proj}}}/{name}" id="{R}builder.{uid(cid,'b')}" keepEnvironmentInBuildfile="false" managedBuildOn="true" name="Gnu Make Builder" superClass="{R}builder"/>{tools}
						</toolChain>
					</folderInfo>
					<sourceEntries>
						<entry flags="VALUE_WORKSPACE_PATH|RESOLVED" kind="sourcePath" name=""/>
					</sourceEntries>
				</configuration>
			</storageModule>
			<storageModule moduleId="org.eclipse.cdt.core.externalSettings"/>
		</cconfiguration>
'''

def cproject(proj):
    return f'''<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<?fileVersion 4.0.0?><cproject storage_type_id="org.eclipse.cdt.core.XmlProjectDescriptionStorage">
	<storageModule moduleId="org.eclipse.cdt.core.settings">
{cconfig(proj, 'debug')}{cconfig(proj, 'release')}	</storageModule>
	<storageModule moduleId="cdtBuildSystem" version="4.0.0">
		<project id="{proj}.{R}target.elf.{uid(proj,'t')}" name="Executable" projectType="{R}target.elf"/>
	</storageModule>
	<storageModule moduleId="scannerConfiguration">
		<autodiscovery enabled="true" problemReportingEnabled="true" selectedProfileId=""/>
	</storageModule>
	<storageModule moduleId="org.eclipse.cdt.core.LanguageSettingsProviders"/>
	<storageModule moduleId="refreshScope"/>
</cproject>
'''

def project(proj):
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<projectDescription>
	<name>{proj}</name>
	<comment>mmRISC-2 bare-metal program (LitexSystem/docs/ECLIPSE.md)</comment>
	<projects>
	</projects>
	<buildSpec>
		<buildCommand>
			<name>org.eclipse.cdt.managedbuilder.core.genmakebuilder</name>
			<triggers>clean,full,incremental,</triggers>
			<arguments>
			</arguments>
		</buildCommand>
		<buildCommand>
			<name>org.eclipse.cdt.managedbuilder.core.ScannerConfigBuilder</name>
			<triggers>full,incremental,</triggers>
			<arguments>
			</arguments>
		</buildCommand>
	</buildSpec>
	<natures>
		<nature>org.eclipse.cdt.core.cnature</nature>
		<nature>org.eclipse.cdt.managedbuilder.core.managedBuildNature</nature>
		<nature>org.eclipse.cdt.managedbuilder.core.ScannerConfigNature</nature>
	</natures>
	<linkedResources>
		<link>
			<name>common</name>
			<type>2</type>
			<locationURI>PARENT-1-PROJECT_LOC/common</locationURI>
		</link>
	</linkedResources>
	<filteredResources>
		<filter>
			<id>{uid(proj,'f')}</id>
			<name></name>
			<type>10</type>
			<matcher>
				<id>org.eclipse.ui.ide.multiFilter</id>
				<arguments>1.0-name-matches-false-false-out</arguments>
			</matcher>
		</filter>
	</filteredResources>
</projectDescription>
'''

def launch(proj, wire):
    cfg = 'ft2232h_jtag.cfg' if wire == 'JTAG' else 'ft2232h_cjtag.cfg'
    A = 'ilg.gnumcueclipse.debug.gdbjtag.openocd.'
    C = 'org.eclipse.cdt.debug.gdbjtag.core.'
    gdbcmds = ('set mem inaccessible-by-default off&#10;set arch riscv:rv64&#10;'
               'set remote hardware-breakpoint-limit 4&#10;set remote hardware-watchpoint-limit 4')
    return f'''<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<launchConfiguration type="{A}launchConfigurationType">
    <booleanAttribute key="{A}doContinue" value="true"/>
    <booleanAttribute key="{A}doDebugInRam" value="false"/>
    <booleanAttribute key="{A}doFirstReset" value="false"/>
    <booleanAttribute key="{A}doGdbServerAllocateConsole" value="true"/>
    <booleanAttribute key="{A}doGdbServerAllocateTelnetConsole" value="false"/>
    <booleanAttribute key="{A}doSecondReset" value="false"/>
    <booleanAttribute key="{A}doStartGdbCLient" value="true"/>
    <booleanAttribute key="{A}doStartGdbServer" value="true"/>
    <booleanAttribute key="{A}enableSemihosting" value="false"/>
    <stringAttribute key="{A}firstResetType" value="init"/>
    <stringAttribute key="{A}gdbClientOtherCommands" value="{gdbcmds}"/>
    <stringAttribute key="{A}gdbClientOtherOptions" value=""/>
    <stringAttribute key="{A}gdbServerConnectionAddress" value=""/>
    <stringAttribute key="{A}gdbServerExecutable" value="${{openocd_path}}/${{openocd_executable}}"/>
    <intAttribute key="{A}gdbServerGdbPortNumber" value="3333"/>
    <stringAttribute key="{A}gdbServerLog" value=""/>
    <stringAttribute key="{A}gdbServerOther" value="-f &quot;${{project_loc}}/../../../../FPGA/ARTY_A7_100T/openocd/{cfg}&quot;"/>
    <stringAttribute key="{A}gdbServerTclPortNumber" value="6666"/>
    <intAttribute key="{A}gdbServerTelnetPortNumber" value="4444"/>
    <stringAttribute key="{A}otherInitCommands" value=""/>
    <stringAttribute key="{A}otherRunCommands" value="set $pc = _start"/>
    <stringAttribute key="{A}secondResetType" value="halt"/>
    <stringAttribute key="ilg.gnumcueclipse.debug.gdbjtag.svdPath" value=""/>
    <stringAttribute key="{C}imageFileName" value=""/>
    <stringAttribute key="{C}imageOffset" value=""/>
    <stringAttribute key="{C}ipAddress" value="localhost"/>
    <stringAttribute key="{C}jtagDevice" value="GNU MCU OpenOCD"/>
    <booleanAttribute key="{C}loadImage" value="true"/>
    <booleanAttribute key="{C}loadSymbols" value="true"/>
    <stringAttribute key="{C}pcRegister" value=""/>
    <intAttribute key="{C}portNumber" value="3333"/>
    <booleanAttribute key="{C}setPcRegister" value="false"/>
    <booleanAttribute key="{C}setResume" value="false"/>
    <booleanAttribute key="{C}setStopAt" value="true"/>
    <stringAttribute key="{C}stopAt" value="main"/>
    <stringAttribute key="{C}symbolsFileName" value=""/>
    <stringAttribute key="{C}symbolsOffset" value=""/>
    <booleanAttribute key="{C}useFileForImage" value="false"/>
    <booleanAttribute key="{C}useFileForSymbols" value="false"/>
    <booleanAttribute key="{C}useProjBinaryForImage" value="true"/>
    <booleanAttribute key="{C}useProjBinaryForSymbols" value="true"/>
    <booleanAttribute key="{C}useRemoteTarget" value="true"/>
    <stringAttribute key="org.eclipse.cdt.dsf.gdb.DEBUG_NAME" value="${{cross_prefix}}gdb${{cross_suffix}}"/>
    <booleanAttribute key="org.eclipse.cdt.dsf.gdb.UPDATE_THREADLIST_ON_SUSPEND" value="false"/>
    <intAttribute key="org.eclipse.cdt.launch.ATTR_BUILD_BEFORE_LAUNCH_ATTR" value="2"/>
    <stringAttribute key="org.eclipse.cdt.launch.PROGRAM_NAME" value="Debug/{proj}.elf"/>
    <stringAttribute key="org.eclipse.cdt.launch.PROJECT_ATTR" value="{proj}"/>
    <booleanAttribute key="org.eclipse.cdt.launch.PROJECT_BUILD_CONFIG_AUTO_ATTR" value="false"/>
    <stringAttribute key="org.eclipse.cdt.launch.PROJECT_BUILD_CONFIG_ID_ATTR" value=""/>
    <listAttribute key="org.eclipse.debug.core.MAPPED_RESOURCE_PATHS">
        <listEntry value="/{proj}"/>
    </listAttribute>
    <listAttribute key="org.eclipse.debug.core.MAPPED_RESOURCE_TYPES">
        <listEntry value="4"/>
    </listAttribute>
    <stringAttribute key="process_factory_id" value="org.eclipse.cdt.dsf.gdb.GdbProcessFactory"/>
</launchConfiguration>
'''

for d in sys.argv[1:]:
    d = d.rstrip('/')
    proj = os.path.basename(os.path.abspath(d))
    for name, text in [('.project', project(proj)), ('.cproject', cproject(proj)),
                       (f'{proj} Debug JTAG.launch', launch(proj, 'JTAG')),
                       (f'{proj} Debug cJTAG.launch', launch(proj, 'cJTAG'))]:
        with open(os.path.join(d, name), 'w') as f:
            f.write(text)
    print(f'{d}: .project, .cproject, 2 launch configurations')

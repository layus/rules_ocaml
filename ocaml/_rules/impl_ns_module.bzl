load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@bazel_skylib//lib:paths.bzl", "paths")

load("//ocaml/_providers:ocaml.bzl",
    "CompilationModeSettingProvider",
     "OcamlModuleProvider",
     "OcamlNsModulePayload",
     "OcamlNsModuleProvider")
load("//ppx:_providers.bzl",
     "PpxNsModuleProvider")

load("//ocaml/_functions:utils.bzl",
     "capitalize_initial_char",
     "get_opamroot",
     "get_sdkpath",
)

load("//ocaml/_deps:depsets.bzl", "get_all_deps")

tmpdir = "_obazl_/"

###########################
def get_resolver_name(ctx):
    if ctx.workspace_name == "__main__": # default, if not explicitly named
        ws = "Main"
    else:
        ws = ctx.workspace_name
        # print("WS: %s" % ws)
    ws = capitalize_initial_char(ws)
    ns_prefix = ws + "_" + ctx.label.package.replace("/", "_").replace("-", "_") + "__"
    ns_main   = ctx.label.name
    resolver_name = ns_prefix + "_" + ns_main + "_00"
    # resolver_name = ws + "_" + ctx.label.package.replace("/", "_").replace("-", "_")
    return resolver_name

########################
def build_resolver(ctx, tc, env, mode, aliases):
    ## always: <pkg>_<nsmain>_00
    resolver_module_name = get_resolver_name(ctx)
    resolver_filename = tmpdir + resolver_module_name + ".ml"
    resolver_file = ctx.actions.declare_file(resolver_filename)
    ctx.actions.write(
        output = resolver_file,
        content = "\n".join(aliases) + "\n"
    )

    ## now compile it
    outputs = []
    directs = []

    resolver_cmi_fname = resolver_module_name + ".cmi"
    resolver_cmi = ctx.actions.declare_file(tmpdir + resolver_cmi_fname)
    outputs.append(resolver_cmi)
    directs.append(resolver_cmi)

    if mode == "bytecode":
        resolver_cm__fname = resolver_module_name + ".cmo"
    else:
        resolver_cm__fname = resolver_module_name + ".cmx"

    resolver_cm_ = ctx.actions.declare_file(tmpdir + resolver_cm__fname)
    outputs.append(resolver_cm_)
    directs.append(resolver_cm_)

    #### now compile
    ################################
    args = ctx.actions.args()

    if mode == "bytecode":
        args.add(tc.ocamlc.basename)
    else:
        args.add(tc.ocamlopt.basename)
        resolver_o_fname = resolver_module_name + ".o"
        resolver_o = ctx.actions.declare_file(tmpdir + resolver_o_fname)
        outputs.append(resolver_o)
        directs.append(resolver_o)

    if ctx.attr._warnings:
        args.add_all(ctx.attr._warnings[BuildSettingInfo].value, before_each="-w", uniquify=True)

    if hasattr(ctx.attr, "opts"):
        args.add_all(ctx.attr.opts)

    ## -no-alias-deps is REQUIRED for ns modules;
    ## see https://caml.inria.fr/pub/docs/manual-ocaml/modulealias.html
    args.add("-no-alias-deps")

    args.add("-c")
    args.add("-o", resolver_cm_)
    args.add(resolver_file.path)

    ctx.actions.run(
        env = env,
        executable = tc.ocamlfind,
        arguments = [args],
        inputs = [resolver_file],
        outputs = outputs,
        tools = [tc.ocamlfind, tc.ocamlopt],
        mnemonic = "OcamlNsResolverAction" if ctx.attr._rule == "ocaml_ns" else "PpxNsResolverAction",
        progress_message = "{mode} compiling ns resolver: {resolver}".format(
            mode = mode,
            resolver = resolver_module_name
        )
    )
    return [resolver_module_name, outputs]

########################
# def user_main_to_ns_main(ctx, ns_file):
#     ## user provided ns main module in 'main' attribute
#     ## we need to copy it to ctx.label.name + ".ml"

#     ctx.actions.run_shell(
#         inputs  = [ctx.file.main],
#         outputs = [ns_file],
#         command = "cp {src} {dest}".format(src = ctx.file.main.path, dest = ns_file.path),
#         progress_message = "Copying user-provide main ns module to {ns}.".format(ns = ctx.label.name + ".ml")
#     )

#     return ns_file

#################
def impl_ns_module(ctx):

    debug = False
    # if (ctx.label.name == "stdune"):
    #     debug = True

    if (ctx.attr.footer and ctx.attr.main):
        fail("Attributes 'footer' and 'main' are mutually exclusive.")

    tc = ctx.toolchains["@obazl_rules_ocaml//ocaml:toolchain"]
    env = {"OPAMROOT": get_opamroot(),
           "PATH": get_sdkpath(ctx)}

    mydeps = get_all_deps(ctx.attr._rule, ctx)

    if debug:
        print("MYDEPS.opam: %s" % mydeps.opam)

    ## generate content: one alias per submodule
    aliases = []
    # pfx = capitalize_initial_char(ctx.attr.ns) + ctx.attr.ns_sep
    dep_graph = []
    includes   = []
    indirects  = []

    # print("XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX")
    # print(mydeps.nopam)
    for dep in mydeps.nopam.to_list():
        # print("DEP: %s" % dep)
        dep_graph.append(dep)
        # indirects.append(dep)
        includes.append(dep.dirname)

    ## compute ns names.
    ## ns module name is always ctx.label.name
    ## if no main, use ns module as resolver (generate it)
    ## otherwise, use main as ns module, and the resolver is computed from package name
    ## ns module always named from ctx.label.name; if main provided is different, we will copy it.
    # if ctx.attr.ns:
    #     ns_module_name = resolver_module_name + "__" + ctx.label.name.replace("-", "_")
    # else:

    ## main ns module name always derived from ocaml_ns_module.name
    ns_module_name = ctx.label.name.replace("-", "_")
    print("NS_MODULE_NAME: %s" % ns_module_name)

    ns_filename = tmpdir + ns_module_name + ".ml"
    ns_file = None

    ## make aliases, one per submodule regardless of pkg
    ## the aliasing equations for this ns module may resolve to any pkg
    ## We may use main ns or submodules from other pkgs, but we do not use their resolvers.
    ## one reason for this is that there is no requirement that modules names match file names.
    ## so the same submodule could go under different submodule names in different packages.
    ## or even in different main ns modules in the same pkg.
    ## So: we always need to generate a resolver for the current package.

    ## Alternatively: module filenames are independent of aliasing
    ## equations. So to construct a resolver all we need is the
    ## filename, not the local resolver. In fact a given module may be
    ## resolved by multiple resolvers local to its own pkg (e.g. if
    ## the ns_modules use different 'prefix' values.)

    ## In short: deriving alias equations from submodule items will always work.

    for (smdep,smname) in ctx.attr.submodules.items():
        # print("SUBMOD: {nm} -> {mod}".format(nm=smname, mod=smdep))
        smimpl = None
        if OcamlNsModuleProvider in smdep:
            print("Got OcamlNsModuleProvider")
        elif OcamlModuleProvider in smdep:
            print("Got OcamlModuleProvider")
        else:
            print("Got ????????????????")
            print(smdep)

        for dep in smdep.files.to_list():
            # print("D: %s" % dep)
            if dep.extension == "cmi":
                bn = dep.basename
                ext = dep.extension
                smimpl = bn[:-(len(ext)+1)]

        # now construct alias statement
        alias = "module {sm} = {smimpl}".format(
            sm=capitalize_initial_char(smname),
            smimpl = capitalize_initial_char(smimpl)
        )
        aliases.append(alias)

    # print("ALIASES: %s" % aliases)

    mode = None
    if ctx.attr._rule == "ocaml_ns":
        mode = ctx.attr._mode[CompilationModeSettingProvider].value
    elif ctx.attr._rule == "ppx_ns":
        mode = ctx.attr._mode[CompilationModeSettingProvider].value

    ## now we need to generate the resolver file. if no 'main' has
    ## been provided, then the generated ns module doubles as the resolver.
    ## if 'main' has been provided, then:
    ##     if it has the same name as the ocaml_ns_module, then:
    ##         use the provided 'main' directly as the ns module
    ##         generate resolver, named <pkg>_<ns-main>_00
    ##     if it has a different name, then:
    ##         copy provided 'main' file to the ocaml_ns_module name
    ##         generate resolver, named <pkg>_<ns-main>_00
    ## in sum: the ns module name will always be taken from ocaml_ns_module.name,
    ## and the resolver will always be generated, with name <pkg>_<nsmain>_00

    resolver_module_name = None
    resolver_files = None

    if ctx.file.main:

        ## assumption is that main contains recursive alias equations,
        ## so we always use a separate resolver module, no matter what 'main' name is,
        ## because main ns module will always match ctx.label.name
        ## iow, using 'main' attrib obligates user to provide first-level aliases.

        ## main file has its own deps! use 'deps' attrib for those?

        ## RESOLVER module:
        ## Each pkg has its own resolver.
        ## The main ns needs one resolver per unique pkg in its submodule list.
        ## If the pkg of this ns module contains submodules, then we need to generate its resolver.

        local_submodules = []
        for submod in ctx.attr.submodules:
            if ctx.label.package == submod.label.package:
                local_submodules.append(submod)
        for sub in local_submodules:
            print("Submodule: %s" % sub)

        ##
        ## Q: do we need to -open the resolvers in order to compile the main ns module?

        # print("RESOLVER_MODULE_NAME: %s" % resolver_module_name)
        # print("Resolver files: %s" % resolver_files)

        ## then we need to copy main to label.name, unless it already has that name
        ## output: ns_file, same as below
        if ctx.file.main.basename == ctx.label.name + ".ml":
            ns_file = ctx.file.main
            [resolver_module_name, resolver_files] = build_resolver(ctx, tc, env, mode, aliases)
            # resolver_module_name = get_resolver_name(ctx)
        else:
            # resolver_module_name = get_resolver_name(ctx)
            [resolver_module_name, resolver_files] = build_resolver(ctx, tc, env, mode, aliases)
            ns_file = ctx.actions.declare_file(ns_filename)
            # ns_file = user_main_to_ns_main(ctx, ns_file)
            ctx.actions.run_shell(
                inputs  = [ctx.file.main],
                outputs = [ns_file],
                command = "cp {src} {dest}".format(src = ctx.file.main.path, dest = ns_file.path),
                progress_message = "Copying user-provided main ns module to {ns}.".format(
                    ns = ctx.label.name + ".ml"
                )
            )
    else:
        ## no user-supplied main, so we need to generate main ns module as output,
        ## and concat footer if present. in this case we do not use a separate resolver module
        ns_file = ctx.actions.declare_file(ns_filename)

        cmd = ""
        for alias in aliases:
            cmd = cmd + "echo \"" + alias + "\" >> " + ns_file.path + "\n"

        cmd = cmd + "echo \"\n(**** everything above this line was generated ****)\n\" >> " + ns_file.path + "\n"
        if ctx.file.footer:
            cmd = cmd + "cat {src} >> {out}".format(
                src = ctx.file.footer.path,
                out = ns_file.path
            )

        # print("CMD: %s" % cmd)

        infile = None
        if ctx.file.footer:
            infile = ctx.file.footer

        ctx.actions.run_shell(
            inputs  = [infile] if infile else [],
            outputs = [ns_file],
            command = cmd,
            progress_message = "Generating namespace module source file."
        )

    # print("RESOLVER_MODULE_NAME: %s" % resolver_module_name)



    ## at this point, either ns_file contains either a user-supplied main ns
    ## module, or we generated it

    ## now declare compilation outputs. compiling always produces 3 files:
    obj_cmi_fname = ns_module_name + ".cmi"
    obj_cmi = ctx.actions.declare_file(tmpdir + obj_cmi_fname)
    if mode == "native":
        obj_cm__fname = ns_module_name + ".cmx" # tc.objext
    else:
        obj_cm__fname = ns_module_name + ".cmo" # tc.objext
        obj_cm_ = ctx.actions.declare_file(tmpdir + obj_cm__fname)

    outputs = []
    directs = []

    #### now compile
    ################################
    args = ctx.actions.args()

    if mode == "bytecode":
        args.add(tc.ocamlc.basename)
    else:
        args.add(tc.ocamlopt.basename)
        obj_o_fname = ns_module_name + ".o"
        obj_o = ctx.actions.declare_file(tmpdir + obj_o_fname)
        outputs.append(obj_o)
        directs.append(obj_o)

    outputs.append(obj_cm_)
    outputs.append(obj_cmi)

    if ctx.attr._warnings:
        args.add_all(ctx.attr._warnings[BuildSettingInfo].value, before_each="-w", uniquify=True)

    if hasattr(ctx.attr, "opts"):
        args.add_all(ctx.attr.opts)

    # dep_graph.append(ns_compile_src)
    # args.add("-I", ns_compile_src.dirname)
    # if not ctx.file.main:
    dep_graph.append(ns_file)

    # if ctx.attr.ns:
    #     for f in ctx.files.ns:
    #         dep_graph.append(f)

    args.add("-absname")
    args.add_all(includes, before_each="-I", uniquify = True)
    args.add("-color", "auto")

    # for dep in ctx.files.deps:
    #     # dep_graph.append(dep)
    #     args.add("-I", dep.path)

    ## -no-alias-deps is REQUIRED for ns modules;
    ## see https://caml.inria.fr/pub/docs/manual-ocaml/modulealias.html
    args.add("-no-alias-deps")

    if resolver_files:
        ## only if ctx.attr.main
        # if not clash:
        for f in resolver_files:
            print("RESOLVER FILE: %s" % f.basename)
            dep_graph.append(f)
            directs.append(f)
            ## don't put cmi files on cmd line
            if ((f.extension == "cmo") or (f.extension == "cmx")):
                args.add("-I", f.dirname) # without this the cmi file may not be found, giving "Unbound module"
                args.add(f)

    if resolver_module_name:
        args.add("-open", resolver_module_name)

    args.add("-c")
    args.add("-o", obj_cm_)
    # if not ctx.file.main:
    args.add(ns_file.path)

    ctx.actions.run(
        env = env,
        executable = tc.ocamlfind,
        arguments = [args],
        inputs = dep_graph, # [ns_file],
        outputs = outputs,
        tools = [tc.ocamlfind, tc.ocamlopt],
        mnemonic = "OcamlNsModuleAction" if ctx.attr._rule == "ocaml_ns" else "PpxNsModuleAction",
        progress_message = "{mode} compiling: @{ws}//{pkg}:{tgt} (rule {rule})".format(
            mode = mode,
            ws  = ctx.label.workspace_name if ctx.label.workspace_name else ctx.workspace_name,
            pkg = ctx.label.package,
            rule=ctx.attr._rule,
            tgt=ctx.label.name,
        )
    )

    provider = None
    if ctx.attr._rule == "ocaml_ns":
        if mode == "native":
            payload = OcamlNsModulePayload(
                # ns  = ctx.attr.ns,
                # sep = ctx.attr.ns_sep,
                cmi = obj_cmi,
                cmx  = obj_cm_,
                o   = obj_o
            )
            directs.append(obj_o)
        else:
            payload = OcamlNsModulePayload(
                # ns  = ctx.attr.ns,
                # sep = ctx.attr.ns_sep,
                cmi = obj_cmi,
                cmo  = obj_cm_,
            )
        provider = OcamlNsModuleProvider(
            payload = payload,
            deps = struct(
                opam  = mydeps.opam,
                nopam = mydeps.nopam
            )
        )
    else:
        ## ppx_ns
        if mode == "native":
            payload = struct(
                # ns  = ctx.attr.ns,
                # sep = ctx.attr.ns_sep,
                cmi = obj_cmi,
                cmx  = obj_cm_,
                o   = obj_o
            )
            directs.append(obj_o)
        else:
            payload = struct(
                # ns  = ctx.attr.ns,
                # sep = ctx.attr.ns_sep,
                cmi = obj_cmi,
                cmo  = obj_cm_,
            )

        provider = PpxNsModuleProvider(
            payload = payload,
            deps = struct(
                opam  = mydeps.opam,
                nopam = mydeps.nopam
            )
        )

    # print("NOPAM: %s" % mydeps.nopam)

    directs.append(obj_cm_)
    directs.append(obj_cmi)
    # for k in ctx.attr.submodules.keys():
    #     for dep in k.files.to_list():
    #         # nopam v. opam
    #         indirects.append(dep)

    # since output may include a generated resolver module, which is not in mydeps,
    # we just put everything into the DefaultInfo depset.
    # we still need the NS provider, for the opam deps at least.

    # print("PROVIDER: %s" % provider)

    return [
        DefaultInfo(files = depset(
            order = "postorder",
            direct = directs,
            transitive = [mydeps.nopam] # , mydeps.opam]
                          # depset(order="postorder", direct = indirects)]
        )),
        provider
    ]


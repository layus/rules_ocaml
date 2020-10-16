load("@bazel_skylib//lib:paths.bzl", "paths")
load("//ocaml/_providers:ocaml.bzl",
     "OcamlSDK",
     "OcamlArchiveProvider",
     "OcamlInterfaceProvider",
     "OcamlLibraryProvider",
     "OcamlModuleProvider",
     "OcamlNsModuleProvider")
load("//ocaml/_providers:opam.bzl", "OpamPkgInfo")
load("//ocaml/_providers:ppx.bzl",
     "PpxArchiveProvider",
     "PpxExecutableProvider")
load("//ocaml/_actions:rename.bzl", "rename_module")
load("//ocaml/_actions:ppx_transform.bzl", "ppx_transform_action")
load("//ocaml/_actions:ppx.bzl",
     "apply_ppx",
     "ocaml_ppx_compile",
     # "ocaml_ppx_apply",
     "ocaml_ppx_library_gendeps",
     "ocaml_ppx_library_cmo",
     "ocaml_ppx_library_compile",
     "ocaml_ppx_library_link")

load("//ocaml/_utils:deps.bzl", "get_all_deps")

load("//implementation:utils.bzl",
     "capitalize_initial_char",
     "get_opamroot",
     "get_sdkpath",
     "get_src_root",
     "strip_ml_extension",
     "OCAML_FILETYPES",
     "OCAML_IMPL_FILETYPES",
     "OCAML_INTF_FILETYPES",
     "WARNING_FLAGS"
)

########## RULE:  OCAML_INTERFACE  ################
def _ocaml_interface_impl(ctx):

  debug = False
  if (ctx.label.name == "Filter_cmi"):
      debug = True

  if debug:
      print("OCAML INTERFACE TARGET: %s" % ctx.label.name)

  mydeps = get_all_deps("ocaml_interface", ctx) # ctx.attr.deps)
  # print("ALL DEPS for target %s" % ctx.label.name)
  # print(mydeps)

  tc = ctx.toolchains["@obazl_rules_ocaml//ocaml:toolchain"]
  env = {"OPAMROOT": get_opamroot(),
         "PATH": get_sdkpath(ctx)}

  dep_graph = []

  xsrc = None
  opam_deps = []
  nopam_deps = []

  build_deps = []
  dso_deps = []
  includes   = []

  if ctx.attr.ppx:
      ## this will also handle ns
    xsrc = ppx_transform_action("ocaml_interface", ctx, ctx.file.src)
  elif ctx.attr.ns_module:
    xsrc = rename_module(ctx, ctx.file.src) #, ctx.attr.ns)
  else:
    xsrc = ctx.file.src

  # cmifname = ctx.file.src.basename.rstrip("mli") + "cmi"
  cmifname = xsrc.basename.rstrip("mli") + "cmi"
  obj_cmi = ctx.actions.declare_file(cmifname)

  args = ctx.actions.args()
  # args.add(tc.compiler.basename)
  args.add("ocamlc")
  # options = tc.opts + ctx.attr.opts
  # args.add_all(options)
  args.add_all(ctx.attr.opts)

  args.add("-c") # interfaces always compile-only?

  if ctx.attr.ns_module:
    # args.add("-no-alias-deps")
    # args.add("-opaque")
    ns_cm = ctx.attr.ns_module[OcamlNsModuleProvider].payload.cm
    ns_mod = capitalize_initial_char(paths.split_extension(ns_cm.basename)[0])
    args.add("-open", ns_mod)
    dep_graph.append(ctx.attr.ns_module[OcamlNsModuleProvider].payload.cm)
    dep_graph.append(ctx.attr.ns_module[OcamlNsModuleProvider].payload.cmi)

    # capitalize_initial_char(ctx.attr.ns_module[PpxNsModuleProvider].payload.ns))

  # if ctx.attr.ns:
  #   args.add("-open", ctx.attr.ns)
  args.add("-I", obj_cmi.dirname)

  # args.add("-linkpkg")
  # args.add("-linkall")

  ppx_opam_lazy_deps = []
  ppx_nopam_lazy_deps = []

  ## FIXME: use mydeps.opam_lazy
  if ctx.attr.ppx:
    if PpxExecutableProvider in ctx.attr.ppx:
        ppx_opam_lazy_deps = ctx.attr.ppx[PpxExecutableProvider].deps.opam_lazy
        for dep in ppx_opam_lazy_deps.to_list():
            for p in dep.pkg.to_list():
                opam_deps.append(p.name)
        ppx_nopam_lazy_deps = ctx.attr.ppx[PpxExecutableProvider].deps.nopam_lazy
        for lazy_dep in ppx_nopam_lazy_deps.to_list():
            if debug:
                print("LAZY DEP: %s" % lazy_dep)
            nopam_deps.append(lazy_dep)
            includes.append(lazy_dep.dirname)

  for dep in mydeps.opam.to_list():
      for x in dep.pkg.to_list():
          opam_deps.append(x.name)

  if len(opam_deps) > 0:
      args.add("-linkpkg")
      for dep in opam_deps:  # mydeps.opam.to_list():
          args.add("-package", dep)

  intf_dep = None

  for dep in mydeps.nopam.to_list():
    if debug:
        print("NOPAM DEP: %s" % dep)
        print("NOPAM DEP ext: %s" % dep.extension)
    if dep.extension == "cmx":
        includes.append(dep.dirname)
        dep_graph.append(dep)
        # ocamlc chokes on cmx when building cmi
        # build_deps.append(dep)
    elif dep.extension == "cmi":
        includes.append(dep.dirname)
        dep_graph.append(dep)
    elif dep.extension == "mli":
        includes.append(dep.dirname)
        dep_graph.append(dep)
    elif dep.extension == "cmxa":
        includes.append(dep.dirname)
        dep_graph.append(dep)
        # build_deps.append(dep)
        # for g in dep[OcamlArchiveProvider].deps.nopam.to_list():
        #     if g.path.endswith(".cmx"):
        #         includes.append(g.dirname)
        #         build_deps.append(g)
        #         dep_graph.append(g)
    elif dep.extension == "o":
        # build_deps.append(dep)
        includes.append(dep.dirname)
        dep_graph.append(dep)
    elif dep.extension == "a":
        # build_deps.append(dep)
        includes.append(dep.dirname)
        dep_graph.append(dep)
    elif dep.extension == "so":
        dso_deps.append(dep)
    else:
        if debug:
            print("NOMAP DEP not .cmx, ,cmxa, .o, .so: %s" % dep.path)

  # print("XXXX DEPS for %s" % ctx.label.name)
  for dep in ctx.attr.deps:
      if debug:
          print("DEP: %s" % dep)
      # if OpamPkgInfo in dep:
      #   g = dep[OpamPkgInfo].pkg.to_list()[0]
      #   args.add("-package", dep[OpamPkgInfo].pkg.to_list()[0].name)
      # else:
      for g in dep[DefaultInfo].files.to_list():
          if debug:
              print("DEPFILE %s" % g)
          # print(g)
          # if g.path.endswith(".o"):
          #   dep_graph.append(g)
          #   includes.append(g.dirname)
          if g.path.endswith(".cmx"):
              dep_graph.append(g)
              includes.append(g.dirname)
          elif g.path.endswith(".cmxa"):
              dep_graph.append(g)
              includes.append(g.dirname)
              ## expose cmi files of deps for linking
              for h in dep[OcamlArchiveProvider].deps.nopam.to_list():
                  # print("LIBDEP: %s" % h)
                  if h.path.endswith(".cmx"):
                      dep_graph.append(h)
                      includes.append(h.dirname)
          elif g.path.endswith(".cmi"):
              intf_dep = g
              #   dep_graph.append(g)
              includes.append(g.dirname)

  args.add_all(includes, before_each="-I", uniquify = True)
  args.add_all(build_deps)

  args.add("-o", obj_cmi)

  # args.add(ctx.file.src)
  args.add("-intf", xsrc)

  dep_graph.append(xsrc) #] + build_deps
  if ctx.attr.ns_module:
    dep_graph.append(ctx.attr.ns_module[OcamlNsModuleProvider].payload.cm)

  ctx.actions.run(
    env = env,
    executable = tc.ocamlfind,
    arguments = [args],
    inputs = dep_graph,
    outputs = [obj_cmi],
    tools = [tc.ocamlopt],
    mnemonic = "OcamlModuleInterface",
    progress_message = "ocaml_interface compile {}".format(
        # ctx.label.name,
        ctx.attr.msg
      )
  )

  if debug:
      print("IF OUT: %s" % obj_cmi)

  interface_provider = OcamlInterfaceProvider(
    payload = struct(cmi = obj_cmi, mli = xsrc),
    deps = struct(
      opam  = mydeps.opam,
      nopam = mydeps.nopam
    )
  )

  return [DefaultInfo(files = depset(direct = [obj_cmi])),
          interface_provider]

# (library
#  (name deriving_hello)
#  (libraries base ppxlib)
#  (preprocess (pps ppxlib.metaquot))
#  (kind ppx_deriver))

#############################################
########## DECL:  OCAML_INTERFACE  ################
ocaml_interface = rule(
  implementation = _ocaml_interface_impl,
  attrs = dict(
    _sdkpath = attr.label(
      default = Label("@ocaml//:path")
    ),
    module_name   = attr.string(
      doc = "Module name."
    ),
    # ns   = attr.string(
    #   doc = "Namespace string; will be used as module name prefix."
    # ),
    ns_sep = attr.string(
      doc = "Namespace separator.  Default: '__'",
      default = "__"
    ),
    ns_module = attr.label(
      doc = "Label of a ocaml_ns_module target. Used to derive namespace, output name, -open arg, etc.",
    ),
    opts = attr.string_list(),
    linkopts = attr.string_list(),
    linkall = attr.bool(default = True),
    src = attr.label(
      allow_single_file = OCAML_INTF_FILETYPES
    ),
    ppx  = attr.label(
      doc = "PPX binary (executable).",
      allow_single_file = True,
      providers = [PpxExecutableProvider]
    ),
    ppx_args  = attr.string_list(
      doc = "Options to pass to PPX binary.",
    ),
    ppx_runtime_deps  = attr.label_list(
        doc = "PPX dependencies. E.g. a file used by %%import from ppx_optcomp.",
        allow_files = True,
    ),
    # ppx = attr.label_keyed_string_dict(
    #   doc = """Dictionary of one entry. Key is a ppx target, val string is arguments."""
    # ),
    deps = attr.label_list(
      providers = [[OpamPkgInfo],
                   [OcamlArchiveProvider],
                   [OcamlLibraryProvider],
                   [PpxArchiveProvider],
                   [OcamlModuleProvider]]
    ),
    mode = attr.string(default = "native"),
    msg = attr.string(),
  ),
  provides = [OcamlInterfaceProvider],
  # provides = [DefaultInfo, OutputGroupInfo, PpxInfo],
  executable = False,
  toolchains = ["@obazl_rules_ocaml//ocaml:toolchain"],
)

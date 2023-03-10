# The WICVARS variable is used to define list of bitbake variables used in wic code
# variables from this list is written to <image>.env file
WICVARS ?= "\
           BBLAYERS IMGDEPLOYDIR DEPLOY_DIR_IMAGE FAKEROOTCMD IMAGE_BASENAME IMAGE_BOOT_FILES \
           IMAGE_LINK_NAME IMAGE_ROOTFS INITRAMFS_FSTYPES INITRD INITRD_LIVE ISODIR RECIPE_SYSROOT_NATIVE \
           ROOTFS_SIZE STAGING_DATADIR STAGING_DIR STAGING_LIBDIR TARGET_SYS TRANSLATED_TARGET_ARCH"

WKS_FILE ??= "${IMAGE_BASENAME}.${MACHINE}.wks"
WKS_FILES ?= "${WKS_FILE} ${IMAGE_BASENAME}.wks"
WKS_SEARCH_PATH ?= "${THISDIR}:${@':'.join('%s/wic' % p for p in '${BBPATH}'.split(':'))}:${@':'.join('%s/scripts/lib/wic/canned-wks' % l for l in '${BBPATH}:${COREBASE}'.split(':'))}"
WKS_FULL_PATH = "${@wks_search(d.getVar('WKS_FILES').split(), d.getVar('WKS_SEARCH_PATH')) or ''}"

def wks_search(files, search_path):
    for f in files:
        if os.path.isabs(f):
            if os.path.exists(f):
                return f
        else:
            searched = bb.utils.which(search_path, f)
            if searched:
                return searched

WIC_CREATE_EXTRA_ARGS ?= ""

IMAGE_CMD_wic () {
	out="${IMGDEPLOYDIR}/${IMAGE_NAME}"
	wks="${WKS_FULL_PATH}"
	if [ -z "$wks" ]; then
		bbfatal "No kickstart files from WKS_FILES were found: ${WKS_FILES}. Please set WKS_FILE or WKS_FILES appropriately."
	fi

	BUILDDIR="${TOPDIR}" wic create "$wks" --vars "${STAGING_DIR}/${MACHINE}/imgdata/" -e "${IMAGE_BASENAME}" -o "$out/" ${WIC_CREATE_EXTRA_ARGS}
	mv "$out/$(basename "${wks%.wks}")"*.direct "$out${IMAGE_NAME_SUFFIX}.wic"
	rm -rf "$out/"
}
IMAGE_CMD_wic[vardepsexclude] = "WKS_FULL_PATH WKS_FILES TOPDIR"

# Rebuild when the wks file or vars in WICVARS change
USING_WIC = "${@bb.utils.contains_any('IMAGE_FSTYPES', 'wic ' + ' '.join('wic.%s' % c for c in '${CONVERSIONTYPES}'.split()), '1', '', d)}"
WKS_FILE_CHECKSUM = "${@'${WKS_FULL_PATH}:%s' % os.path.exists('${WKS_FULL_PATH}') if '${USING_WIC}' else ''}"
do_image_wic[file-checksums] += "${WKS_FILE_CHECKSUM}"
do_image_wic[depends] += "wic-tools:do_populate_sysroot"
WKS_FILE_DEPENDS ??= ''
DEPENDS += "${@ '${WKS_FILE_DEPENDS}' if d.getVar('USING_WIC') else '' }"

# We ensure all artfacts are deployed (e.g virtual/bootloader)
do_image_wic[recrdeptask] += "do_deploy"

python do_write_wks_template () {
    """Write out expanded template contents to WKS_FULL_PATH."""
    import re

    template_body = d.getVar('_WKS_TEMPLATE')

    # Remove any remnant variable references left behind by the expansion
    # due to undefined variables
    expand_var_regexp = re.compile(r"\${[^{}@\n\t :]+}")
    while True:
        new_body = re.sub(expand_var_regexp, '', template_body)
        if new_body == template_body:
            break
        else:
            template_body = new_body

    wks_file = d.getVar('WKS_FULL_PATH')
    with open(wks_file, 'w') as f:
        f.write(template_body)
}

python () {
    if d.getVar('USING_WIC'):
        wks_file_u = d.getVar('WKS_FULL_PATH', False)
        wks_file = d.expand(wks_file_u)
        base, ext = os.path.splitext(wks_file)
        if ext == '.in' and os.path.exists(wks_file):
            wks_out_file = os.path.join(d.getVar('WORKDIR'), os.path.basename(base))
            d.setVar('WKS_FULL_PATH', wks_out_file)
            d.setVar('WKS_TEMPLATE_PATH', wks_file_u)
            d.setVar('WKS_FILE_CHECKSUM', '${WKS_TEMPLATE_PATH}:True')

            # We need to re-parse each time the file changes, and bitbake
            # needs to be told about that explicitly.
            bb.parse.mark_dependency(d, wks_file)

            try:
                with open(wks_file, 'r') as f:
                    body = f.read()
            except (IOError, OSError) as exc:
                pass
            else:
                # Previously, I used expandWithRefs to get the dependency list
                # and add it to WICVARS, but there's no point re-parsing the
                # file in process_wks_template as well, so just put it in
                # a variable and let the metadata deal with the deps.
                d.setVar('_WKS_TEMPLATE', body)
                bb.build.addtask('do_write_wks_template', 'do_image_wic', None, d)
}

#
# Write environment variables used by wic
# to tmp/sysroots/<machine>/imgdata/<image>.env
#
python do_rootfs_wicenv () {
    wicvars = d.getVar('WICVARS')
    if not wicvars:
        return

    stdir = d.getVar('STAGING_DIR')
    outdir = os.path.join(stdir, d.getVar('MACHINE'), 'imgdata')
    bb.utils.mkdirhier(outdir)
    basename = d.getVar('IMAGE_BASENAME')
    with open(os.path.join(outdir, basename) + '.env', 'w') as envf:
        for var in wicvars.split():
            value = d.getVar(var)
            if value:
                envf.write('%s="%s"\n' % (var, value.strip()))
}
addtask do_rootfs_wicenv after do_image before do_image_wic
do_rootfs_wicenv[vardeps] += "${WICVARS}"
do_rootfs_wicenv[prefuncs] = 'set_image_size'

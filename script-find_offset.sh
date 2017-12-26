#!//bin/sh

export PATH=bin:$PATH

self=$0

function print_help() {
    echo "BY UNBREAKCODE,ACEORO,UROBORO"
	echo "$self [IPSW path]"
	echo "$self [device model] [ios build]"
	echo
	echo "Examples:"
	echo "\t $self iPodtouch_10.3.3_14G60_Restore.ipsw"
	echo "\t $self iPod7,1 14G60"
}

function install_radare2() {
	brew ls --versions radare2 > /dev/null
	if [ ! $? -eq 0 ]; then
		brew update &> /dev/null
		brew install radare2 &> /dev/null
	fi
}

function install_partialzip() {
	if [[ ! -f bin/partialzip ]]; then
		echo "[#] Cloning partial-zip repo..."
		git clone https://github.com/uroboro/partial-zip &> /dev/null
		pushd partial-zip &> /dev/null
		echo "[#] Building..."
		cmake . &> /dev/null
		make &> /dev/null
		popd &> /dev/null
		mkdir -p bin
		cp partial-zip/partialzip bin/
		rm -rf partial-zip
		echo "[#] Done!"
	fi
}

function install_joker() {
	if [[ ! -f bin/joker ]]; then
		echo "[#] Downloading joker..."
		curl -s http://newosxbook.com/tools/joker.tar -o /tmp/joker.tar
		echo "[#] Extracting..."
		tar -xf /tmp/joker.tar joker.universal
		mkdir -p bin
		mv joker.universal bin/joker
		rm /tmp/joker.tar
		echo "[#] Done!"
	fi
}

function extract_from_ipsw() {
	file="$1"
	kernel_name=$(unzip -l $file | grep -m 1 kernelcache | awk '{ print $NF }')
	unzip -p $file $kernel_name > kernelcache.comp
}
function extract_from_url() {
	file="$1"
	kernel_name=$(partialzip -l $file | grep -m 1 kernelcache | awk '{ print $NF }')
 	partialzip $file $kernel_name
	cp $kernel_name kernelcache.comp
}

skip_decompression=0
if [ $# -eq 2 ]; then
	if [[ "$1" == "-k" ]]; then
		cp $2 kernelcache.comp
	elif [[ "$1" == "-d" ]]; then
		skip_decompression=1
		cp $2 kernelcache
	else
		install_partialzip
		file=$(curl -s https://api.ipsw.me/v2.1/$1/$2/url)
		extract_from_url $file
	fi
elif [ $# -eq 1 ]; then
	file=$1
	extract_from_ipsw $file
else
	print_help
	exit 0
fi

# Decompress kernelcache
if [ "$skip_decompression" -eq "0" ]; then
	if [ ! -f kernelcache.comp ]; then
		echo "[#] No kernel cache to work with. Bailing."
		exit 1
	fi

	install_joker
	joker -dec kernelcache.comp &> /dev/null
	if [ ! -f /tmp/kernel ]; then
		echo "[#] No compressed kernel cache to work with. Bailing."
		exit 1
	fi
	mv /tmp/kernel ./kernelcache
else
	echo "[#] Skipping decompression"
fi
# Extract IOSurface kext
install_joker
joker -K com.apple.iokit.IOSurface kernelcache &> /dev/null
if [ ! -f /tmp/com.apple.iokit.IOSurface.kext ]; then
	echo "[#] No usable kernel cache to work with. Bailing."
	exit 1
fi
mv /tmp/com.apple.iokit.IOSurface.kext ./

strings kernelcache | grep 'Darwin K'
echo

function address_kernel_map() {
	nm kernelcache | grep ' _kernel_map$' | awk '{ print "0x" $1 }'
}

function address_kernel_task() {
	nm kernelcache | grep ' _kernel_task$' | awk '{ print "0x" $1 }'
}

function address_bzero() {
	nm kernelcache | grep ' ___bzero$' | awk '{ print "0x" $1 }'
}

function address_bcopy() {
	nm kernelcache | grep ' _bcopy$' | awk '{ print "0x" $1 }'
}

function address_copyin() {
	nm kernelcache | grep ' _copyin$' | awk '{ print "0x" $1 }'
}

function address_copyout() {
	nm kernelcache | grep ' _copyout$' | awk '{ print "0x" $1 }'
}

function address_rootvnode() {
	nm kernelcache | grep ' _rootvnode$' | awk '{ print "0x" $1 }'
}

function address_kauth_cred_ref() {
	nm kernelcache | grep ' _kauth_cred_ref$' | awk '{ print "0x" $1 }'
}

function address_osserializer_serialize() {
	nm kernelcache | grep ' __ZNK12OSSerializer9serializeEP11OSSerialize$' | awk '{ print "0x" $1 }'
}

function address_host_priv_self() {
	host_priv_self_addr=$(nm kernelcache | grep host_priv_self | awk '{ print "0x" $1 }')
	r2 -q -e scr.color=false -c "pd 2 @ $host_priv_self_addr" kernelcache 2> /dev/null | sed -n 's/0x//gp' | awk '{ print $NF }' | tr '[a-f]\n' '[A-F] ' | awk '{ print "obase=16;ibase=16;" $1 "+" $2 }' | bc | tr '[A-F]' '[a-f]' | awk '{ print "0x" $1 }'
}

function address_ipc_port_alloc_special() {
	r2 -e scr.color=false -q -c 'pd @ sym._convert_task_suspension_token_to_port' kernelcache 2> /dev/null | sed -n 's/.*bl sym.func.\([a-z01-9]*\)/0x\1/p' | sed -n 1p
}

function address_ipc_kobject_set() {
	r2 -e scr.color=false -q -c 'pd @ sym._convert_task_suspension_token_to_port' kernelcache 2> /dev/null | sed -n 's/.*bl sym.func.\([a-z01-9]*\)/0x\1/p' | sed -n 2p
}

function address_ipc_port_make_send() {
	r2 -e scr.color=false -q -c 'pd @ sym._convert_task_to_port' kernelcache 2>/dev/null | sed -n 's/.*bl sym.func.\([a-z01-9]*\)/0x\1/p' | sed -n 1p
}

function address_rop_add_x0_x0_0x10() {
	r2 -q -e scr.color=true -c "\"/a add x0, x0, 0x10; ret\"" kernelcache 2> /dev/null | head -n1 | awk '{ print $1 }'
}

function address_rop_ldr_x0_x0_0x10() {
	r2 -q -e scr.color=true -c "\"/a ldr x0, [x0, 0x10]; ret\"" kernelcache 2> /dev/null | head -n1 | awk '{ print $1 }'
}

function address_zone_map() {
	string_addr=$(r2 -q -e scr.color=false -c 'iz~zone_init: kmem_suballoc failed' kernelcache 2> /dev/null | awk '{ print $1 }' | sed 's/.*=//')
	xref1_addr=$(r2 -q -e scr.color=false -c "\"/c $string_addr\"" kernelcache 2> /dev/null | awk '{ print $1 }')
	xref2_addr=$(r2 -q -e scr.color=false -c "\"/c $xref1_addr\"" kernelcache 2> /dev/null | awk '{ print $1 }')
	addr=$(r2 -q -e scr.color=false -c "pd -8 @ $xref2_addr" kernelcache 2> /dev/null | head -n 2 | grep 0x | awk '{ print $NF }' | sed 's/0x//' | tr '[a-f]\n' '[A-F] ' | awk '{ print "obase=16;ibase=16;" $1 "+" $2 }' | bc | tr '[A-F]' '[a-f]')
	echo "0x$addr"
}

function address_chgproccnt() {
	priv_check_cred_addr=$(nm kernelcache | grep ' _priv_check_cred$' | awk '{ print "0x" $1 }')
	r2 -q -e scr.color=false -c "pd 31 @ $priv_check_cred_addr" kernelcache 2> /dev/null | tail -n1 | awk '{ print $1 }'
}

function address_iosurfacerootuserclient_vtab() {
	# Get __DATA_CONST.__const offset and size
	data_const_const=$(r2 -q -e scr.color=false -c 'S' com.apple.iokit.IOSurface.kext 2> /dev/null | grep '__DATA_CONST.__const' | tr ' ' '\n' | grep '=')
	va=$(echo $data_const_const | tr ' ' '\n' | sed -n 's/va=//p')
	sz=$(echo $data_const_const | tr ' ' '\n' | sed -n 's/^sz=//p')

	# Dump hex to tmp file
	r2 -q -e scr.color=false -c "s $va; pxr $sz" com.apple.iokit.IOSurface.kext 2> /dev/null | awk '{ print $1 " " $2 }' > /tmp/hexdump.txt
	IFS=$'\n' read -d '' -r -a hd < /tmp/hexdump.txt
	lines=$(wc -l /tmp/hexdump.txt | awk '{ print $1 }')

	# Go through each line, check if there are 2 consecutive zeros
	found=0
	for (( i = 1; i < $lines; i++ )); do
		# First zero
		zero1=$(echo ${hd[$i]} | awk '{ print $2 }')
		# Second zero
		zero2=$(echo ${hd[$((i+1))]} | awk '{ print $2 }')
		if [ "$zero1" == "0x0000000000000000" -a "$zero2" == "0x0000000000000000" ]; then
			# vtable offset
			offset=$(echo ${hd[$i+2]} | awk '{ print $1 }')
			# echo "found possible offset at $offset"

			# 8th pointer after vtable start
			pointer8=$(echo ${hd[$((i+2+7))]} | awk '{ print $2 }')
			if [ -z "$pointer8" ]; then
				break
			fi

			# Retrieve class name
			cmd_lookup=$(r2 -q -e scr.color=false -c "pd 3 @ $pointer8" com.apple.iokit.IOSurface.kext 2> /dev/null | awk '{ print $NF }' | tr '\n' ' ' | awk '{ print $1 "; " $2 }')
			second_to_last=$(r2 -q -e scr.color=true -c "\"/c $cmd_lookup\"" com.apple.iokit.IOSurface.kext 2>/dev/null | tail -n 2 | head -n 1 | awk '{ print $1 }')
			class_addr=$(r2 -q -e scr.color=false -c "pd 3 @ $second_to_last" com.apple.iokit.IOSurface.kext 2> /dev/null | tail -n 2 | awk '{ print $NF }' | tr '\n' ' ' | awk '{ print $1 "+" $2 }')
			name=$(r2 -q -e scr.color=false -c "ps @ $class_addr" com.apple.iokit.IOSurface.kext 2> /dev/null | sed 's/[^a-zA-Z]//g')

			if [[ ! -z "$name" && "$name" == "IOSurfaceRootUserClient" ]]; then
				# Done!
				found=1
				echo "$offset"
				return 0
			fi
		fi
	done

	echo "0xdeadbeefbabeface"
}

install_radare2

printf "[#] Working...\r"
offset_zone_map=$(address_zone_map)
offset_kernel_map=$(address_kernel_map)
offset_kernel_task=$(address_kernel_task)
offset_host_priv_self=$(address_host_priv_self)
offset_bzero=$(address_bzero)
offset_bcopy=$(address_bcopy)
offset_copyin=$(address_copyin)
offset_copyout=$(address_copyout)
offset_chgproccnt=$(address_chgproccnt)
offset_rootvnode=$(address_rootvnode)
offset_kauth_cred_ref=$(address_kauth_cred_ref)
offset_ipc_port_alloc_special=$(address_ipc_port_alloc_special)
offset_ipc_kobject_set=$(address_ipc_kobject_set)
offset_ipc_port_make_send=$(address_ipc_port_make_send)
offset_iosurfacerootuserclient_vtab=$(address_iosurfacerootuserclient_vtab)
offset_rop_add_x0_x0_0x10=$(address_rop_add_x0_x0_0x10)
offset_osserializer_serialize=$(address_osserializer_serialize)
offset_rop_ldr_x0_x0_0x10=$(address_rop_ldr_x0_x0_0x10)

echo "Official Friendly Offsets:"
echo "#define OFFSET_ZONE_MAP                        $offset_zone_map"
echo "#define OFFSET_KERNEL_MAP                      $offset_kernel_map"
echo "#define OFFSET_KERNEL_TASK                     $offset_kernel_task"
echo "#define OFFSET_REALHOST                        $offset_host_priv_self"
echo "#define OFFSET_BZERO                           $offset_bzero"
echo "#define OFFSET_BCOPY                           $offset_bcopy"
echo "#define OFFSET_COPYIN                          $offset_copyin"
echo "#define OFFSET_COPYOUT                         $offset_copyout"
echo "#define OFFSET_ROOTVNODE                       $offset_rootvnode"
echo "#define OFFSET_CHGPROCCNT                      $offset_chgproccnt"
echo "#define OFFSET_KAUTH_CRED_REF                  $offset_kauth_cred_ref"
echo "#define OFFSET_IPC_PORT_ALLOC_SPECIAL          $offset_ipc_port_alloc_special"
echo "#define OFFSET_IPC_KOBJECT_SET                 $offset_ipc_kobject_set"
echo "#define OFFSET_IPC_PORT_MAKE_SEND              $offset_ipc_port_make_send"
echo "#define OFFSET_IOSURFACEROOTUSERCLIENT_VTAB    $offset_iosurfacerootuserclient_vtab"
echo "#define OFFSET_ROP_ADD_X0_X0_0x10              $offset_rop_add_x0_x0_0x10"
echo "#define OFFSET_OSSERIALIZER_SERIALIZE          $offset_osserializer_serialize"
echo "#define OFFSET_ROP_LDR_X0_X0_0x10              $offset_rop_ldr_x0_x0_0x10"
echo ""
echo ""
echo "v0rtex-S Friendly Offsets:"
echo "OFFSET_ZONE_MAP                             = $offset_zone_map;"
echo "OFFSET_KERNEL_MAP                           = $offset_kernel_map;"
echo "OFFSET_KERNEL_TASK                          = $offset_kernel_task;"
echo "OFFSET_REALHOST                             = $offset_host_priv_self;"
echo "OFFSET_BZERO                                = $offset_bzero;"
echo "OFFSET_BCOPY                                = $offset_bcopy;"
echo "OFFSET_COPYIN                               = $offset_copyin;"
echo "OFFSET_COPYOUT                              = $offset_copyout;"
echo "OFFSET_CHGPROCCNT                           = $offset_chgproccnt;"
echo "OFFSET_KAUTH_CRED_REF                       = $offset_kauth_cred_ref;"
echo "OFFSET_IPC_PORT_ALLOC_SPECIAL               = $offset_ipc_port_alloc_special;"
echo "OFFSET_IPC_KOBJECT_SET                      = $offset_ipc_kobject_set;"
echo "OFFSET_IPC_PORT_MAKE_SEND                   = $offset_ipc_port_make_send;"
echo "OFFSET_IOSURFACEROOTUSERCLIENT_VTAB         = $offset_iosurfacerootuserclient_vtab;"
echo "OFFSET_ROP_ADD_X0_X0_0x10                   = $offset_rop_add_x0_x0_0x10;"
echo "OFFSET_ROP_LDR_X0_X0_0x10                   = $offset_rop_ldr_x0_x0_0x10;"
echo "OFFSET_ROOT_MOUNT_V_NODE                    = $offset_rootvnode;"


# rm com.apple.iokit.IOSurface.kext kernelcache*

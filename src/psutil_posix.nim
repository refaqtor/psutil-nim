import posix
import strutils
import tables

import types

var AF_PACKET* {.importc, header: "<sys/socket.h>".}: cint
var IFF_BROADCAST* {.importc, header: "<net/if.h>".}: uint
var IFF_POINTOPOINT* {.importc, header: "<net/if.h>".}: uint
var NI_MAXHOST* {.importc, header: "<net/if.h>".}: cint

type ifaddrs = object
    pifaddrs: ptr ifaddrs # Next item in list
    ifa_name: cstring # Name of interface
    ifa_flags: uint   # Flags from SIOCGIFFLAGS
    ifa_addr: ptr SockAddr  # Address of interface
    ifa_netmask: ptr SockAddr # Netmask of interface
    ifu_broadaddr: ptr SockAddr # Broadcast address of interface
    ifa_data: pointer # Address-specific data

type sockaddr_ll = object
    sll_family: uint16 # Always AF_PACKET
    sll_protocol: uint16 # Physical-layer protocol */
    sll_ifindex: int32 # Interface number */
    sll_hatype: uint16 # ARP hardware type */
    ll_pkttype: uint8 # Packet type */
    sll_halen: uint8 # Length of address */
    sll_addr: array[8, uint8] # Physical-layer address */


proc getifaddrs( ifap: var ptr ifaddrs ): int
    {.header: "<ifaddrs.h>", importc: "getifaddrs".}

proc freeifaddrs( ifap: ptr ifaddrs ): void
    {.header: "<ifaddrs.h>", importc: "freeifaddrs".}

proc psutil_convert_ipaddr(address: ptr SockAddr, family: int): string


proc pid_exists*( pid: int ): bool =
    ## Check whether pid exists in the current process table.
    if pid == 0:
        # According to "man 2 kill" PID 0 has a special meaning:
        # it refers to <<every process in the process group of the
        # calling process>> so we don't want to go any further.
        # If we get here it means this UNIX platform *does* have
        # a process with id 0.
        return true

    let ret_code = kill( pid, 0 )

    if ret_code == 0: return true

    # ESRCH == No such process
    if errno == ESRCH: return false

    # EPERM clearly means there's a process to deny access to
    elif errno == EPERM: return true

    # According to "man 2 kill" possible error values are
    # (EINVAL, EPERM, ESRCH) therefore we should never get
    # here. If we do let's be explicit in considering this
    # an error.
    else: raise newException(OSError, "Unknown error from pid_exists: " & $errno )


proc net_if_addrs*(): Table[string, seq[Address]] =
    ## Return the addresses associated to each NIC (network interface card)
    ##   installed on the system as a table whose keys are the NIC names and
    ##   value is a seq of Addresses for each address assigned to the NIC.
    ##
    ##   *family* can be either AF_INET, AF_INET6, AF_LINK, which refers to a MAC address.
    ##   *address* is the primary address and it is always set.
    ##   *netmask*, *broadcast* and *ptp* may be ``None``.
    ##   *ptp* stands for "point to point" and references the destination address on a point to point interface (typically a VPN).
    ##   *broadcast* and *ptp* are mutually exclusive.
    ##   *netmask*, *broadcast* and *ptp* are not supported on Windows and are set to nil.
    var interfaces : ptr ifaddrs
    var current : ptr ifaddrs
    let ret_code = getifaddrs( interfaces )
    if ret_code == -1:
        echo( "net_if_addrs error: ", strerror( errno ) )
        return result

    result = initTable[string, seq[Address]]()

    current = interfaces
    while current != nil:
        let name = $current.ifa_name
        let family = current.ifa_addr.sa_family
        let address = psutil_convert_ipaddr( current.ifa_addr, family )
        let netmask = psutil_convert_ipaddr( current.ifa_netmask, family )
        let bc_or_ptp = psutil_convert_ipaddr( current.ifu_broadaddr, family )
        let broadcast = if (current.ifa_flags and IFF_BROADCAST) != 0: bc_or_ptp else: nil
        # ifu_broadcast and ifu_ptp are a union in C, but we don't really care what C calls it
        let ptp = if (current.ifa_flags and IFF_POINTOPOINT) != 0: bc_or_ptp else: nil

        if not( name in result ): result[name] = newSeq[Address]()
        result[name].add( Address( family: family,
                                   address: address,
                                   netmask: netmask,
                                   broadcast: broadcast,
                                   ptp: ptp ) )

        current = current.pifaddrs

    freeifaddrs( interfaces )


proc psutil_convert_ipaddr(address: ptr SockAddr, family: int): string =
    result = newString(NI_MAXHOST)
    var addrlen: Socklen
    var resultLen: Socklen = NI_MAXHOST.uint32

    if address == nil:
        return nil

    if family == AF_INET or family == AF_INET6:
        if family == AF_INET:
            addrlen = sizeof(SockAddr_in).uint32
        else:
            addrlen = sizeof(SockAddr_in6).uint32

        let err = getnameinfo( address, addrlen, result, resultLen, nil, 0, NI_NUMERICHOST )
        if err != 0:
            # // XXX we get here on FreeBSD when processing 'lo' / AF_INET6
            # // broadcast. Not sure what to do other than returning None.
            # // ifconfig does not show anything BTW.
            return nil

        else:
            return result.strip(chars=Whitespace + {'\x00'})

    elif defined(linux) and family == AF_PACKET:
        var hw_address = cast[ptr sockaddr_ll](address)
        # TODO - this is going to break on non-Ethernet addresses (e.g. mac firewire - 8 bytes)
        # psutil actually handles this, i just wanted to test that it was working
        return "$1:$2:$3:$4:$5:$6".format( hw_address.sll_addr[0].int.toHex(2),
                                           hw_address.sll_addr[1].int.toHex(2),
                                           hw_address.sll_addr[2].int.toHex(2),
                                           hw_address.sll_addr[3].int.toHex(2),
                                           hw_address.sll_addr[4].int.toHex(2),
                                           hw_address.sll_addr[5].int.toHex(2) ).tolowerAscii()


    elif ( defined(freebsd) or defined(openbsd) or defined(darwin) or defined(netbsd) ) and family == AF_PACKET:
        # struct sockaddr_dl *dladdr = (struct sockaddr_dl *)addr;
        # len = dladdr->sdl_alen;
        # data = LLADDR(dladdr);
        discard

    else:
        # unknown family
        return nil

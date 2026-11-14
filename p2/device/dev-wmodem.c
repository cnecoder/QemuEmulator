/*
 * QEMU USB cellular modem emulation (usb-wmodem) - composite device
 *
 * Single USB device exposing:
 *   interface 0 (in00): vendor-specific serial (option driver) - AT port
 *   interface 1 (in01): vendor-specific serial (option driver) - diag port
 *   interface 2 (in02): vendor-specific serial (option driver) - nmea port
 *   interface 3 (in03): RNDIS control (class 0xEF/0x02/0x01, like Android/Pi)
 *   interface 4 (in04): RNDIS data (class 0x0a)
 *
 * The 0xEF/0x02/0x01 control layout is chosen over CDC 0x02/0x02/0xff so that
 * rndis_host binds it via its generic match while cdc_acm (which may grab
 * 0x02/0x02/0xff for unknown VIDs) never matches.
 *
 * Serial ports: raw bulk pipes <-> chardev backends (no FTDI protocol),
 * like real WWAN option ports. RNDIS: adapted from hw/usb/dev-network.c.
 *
 * Based on hw/usb/dev-serial.c and hw/usb/dev-network.c (LGPL).
 */

#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qemu/module.h"
#include "qemu/cutils.h"
#include "qemu/queue.h"
#include "qemu/iov.h"
/* QEMU >= 10/11 include layout (hw/usb/usb.h, hw/core/qdev-properties*.h) */
#include "hw/core/qdev-properties.h"
#include "hw/core/qdev-properties-system.h"
#include "hw/usb/usb.h"
#include "migration/vmstate.h"
#include "desc.h"
#include "chardev/char-fe.h"
#include "net/net.h"
#include "qom/object.h"

/* ------------------------------------------------------------------ */
/* tunables                                                            */
/* ------------------------------------------------------------------ */

#define WMODEM_SERIAL_PORTS     3
#define RECV_BUF                4096

#define USB_CDC_SUBCLASS_ACM            0x02
#define USB_CDC_ACM_PROTO_VENDOR        0xff
#define USB_CDC_PROTO_NONE              0

#define USB_CDC_HEADER_TYPE             0x00
#define USB_CDC_CALL_MANAGEMENT_TYPE    0x01
#define USB_CDC_ACM_TYPE                0x02
#define USB_CDC_UNION_TYPE              0x06

/* not defined by hw/usb.h - wireless (RNDIS) class, 0xEF */
#ifndef USB_CLASS_WIRELESS_CONTROLLER
#define USB_CLASS_WIRELESS_CONTROLLER   0xEF
#endif

#define USB_CDC_SEND_ENCAPSULATED_COMMAND       0x00
#define USB_CDC_GET_ENCAPSULATED_RESPONSE       0x01

#define LOG2_STATUS_INTERVAL_MSEC       5
#define STATUS_BYTECOUNT                16
#define ETH_FRAME_LEN                   1514

/* RNDIS control interface: if3; data interface: if4 (see ep routing) */
#define RNDIS_CTRL_IF                   3
#define RNDIS_DATA_IF                   4

/* ------------------------------------------------------------------ */
/* strings / descriptors                                               */
/* ------------------------------------------------------------------ */

enum {
    STR_MANUFACTURER = 1,
    STR_PRODUCT,
    STR_SERIALNUMBER,
    STR_ETHADDR,
    STR_RNDIS_CONTROL,
    STR_DATA,
    STR_RNDIS,
};

static const USBDescStrings desc_strings = {
    [STR_MANUFACTURER]   = "WModem",
    [STR_PRODUCT]        = "QEMU USB WMODEM",
    [STR_SERIALNUMBER]   = "0001",
    [STR_ETHADDR]        = "400102030405",
    [STR_RNDIS_CONTROL]  = "WModem RNDIS Control",
    [STR_DATA]           = "WModem RNDIS Data",
    [STR_RNDIS]          = "WModem RNDIS",
};

/* vendor-specific serial interface template (class 0xff, subclass/protocol 0)
 * NOTE: subclass/protocol 0x00 - option only checks class 0xff, while
 * usbtouchscreen's generic match grabs 0xff/0xff/0xff interfaces. */
#define SERIAL_IFACE_TMPL(num, ep_in, ep_out) \
    {                                                           \
        .bInterfaceNumber       = (num),                        \
        .bNumEndpoints          = 2,                            \
        .bInterfaceClass        = 0xff,                         \
        .bInterfaceSubClass     = 0x00,                         \
        .bInterfaceProtocol     = 0x00,                         \
        .eps = (USBDescEndpoint[]) {                            \
            {                                                   \
                .bEndpointAddress = USB_DIR_IN | (ep_in),       \
                .bmAttributes     = USB_ENDPOINT_XFER_BULK,     \
                .wMaxPacketSize   = 512,                        \
            },{                                                 \
                .bEndpointAddress = USB_DIR_OUT | (ep_out),     \
                .bmAttributes     = USB_ENDPOINT_XFER_BULK,     \
                .wMaxPacketSize   = 512,                        \
            },                                                  \
        },                                                      \
    }

/* Composite layout: interfaces 0-2 = option serial, 3-4 = RNDIS.
 * Interface numbers are the identity the guest software keys on
 * (uevent MODALIAS "in" field) - do not reorder casually. */
static const USBDescIface desc_iface_serial_and_rndis[] = {
    SERIAL_IFACE_TMPL(0, 1, 1),
    SERIAL_IFACE_TMPL(1, 2, 2),
    SERIAL_IFACE_TMPL(2, 3, 3),
    {
        /* RNDIS Control Interface (in03) - class 0xEF/0x04/0x01
         * (rndis_host's generic match; cdc_acm never matches 0xEF) */
        .bInterfaceNumber              = RNDIS_CTRL_IF,
        .bNumEndpoints                 = 1,
        .bInterfaceClass               = USB_CLASS_WIRELESS_CONTROLLER,
        .bInterfaceSubClass            = 0x04,
        .bInterfaceProtocol            = 0x01,
        .iInterface                    = STR_RNDIS_CONTROL,
        .ndesc                         = 5,
        .descs = (USBDescOther[]) {
            {   /* IAD: covers control + data interfaces */
                .data = (uint8_t[]) {
                    0x08,                       /*  u8    bLength */
                    0x11,                       /*  u8    bDescriptorType (IAD) */
                    RNDIS_CTRL_IF,              /*  u8    bFirstInterface */
                    0x02,                       /*  u8    bInterfaceCount */
                    USB_CLASS_WIRELESS_CONTROLLER, /* u8 bFunctionClass */
                    0x04,                       /*  u8    bFunctionSubClass */
                    0x01,                       /*  u8    bFunctionProtocol */
                    0x00,                       /*  u8    iFunction */
                },
            },{
                /* Header Descriptor */
                .data = (uint8_t[]) {
                    0x05,
                    USB_DT_CS_INTERFACE,
                    USB_CDC_HEADER_TYPE,
                    0x10, 0x01,
                },
            },{
                /* Call Management Descriptor */
                .data = (uint8_t[]) {
                    0x05,
                    USB_DT_CS_INTERFACE,
                    USB_CDC_CALL_MANAGEMENT_TYPE,
                    0x00,
                    RNDIS_DATA_IF,
                },
            },{
                /* ACM Descriptor */
                .data = (uint8_t[]) {
                    0x04,
                    USB_DT_CS_INTERFACE,
                    USB_CDC_ACM_TYPE,
                    0x00,
                },
            },{
                /* Union Descriptor */
                .data = (uint8_t[]) {
                    0x05,
                    USB_DT_CS_INTERFACE,
                    USB_CDC_UNION_TYPE,
                    RNDIS_CTRL_IF,              /* bMasterInterface0 */
                    RNDIS_DATA_IF,              /* bSlaveInterface0 */
                },
            },
        },
        .eps = (USBDescEndpoint[]) {
            {
                .bEndpointAddress      = USB_DIR_IN | 0x04,   /* status INT */
                .bmAttributes          = USB_ENDPOINT_XFER_INT,
                .wMaxPacketSize        = STATUS_BYTECOUNT,
                .bInterval             = 1 << LOG2_STATUS_INTERVAL_MSEC,
            },
        }
    },{
        /* RNDIS Data Interface (in04) */
        .bInterfaceNumber              = RNDIS_DATA_IF,
        .bNumEndpoints                 = 2,
        .bInterfaceClass               = USB_CLASS_CDC_DATA,
        .iInterface                    = STR_DATA,
        .eps = (USBDescEndpoint[]) {
            {
                .bEndpointAddress      = USB_DIR_IN | 0x05,   /* data bulk IN */
                .bmAttributes          = USB_ENDPOINT_XFER_BULK,
                .wMaxPacketSize        = 512,
            },{
                .bEndpointAddress      = USB_DIR_OUT | 0x04,  /* data bulk OUT */
                .bmAttributes          = USB_ENDPOINT_XFER_BULK,
                .wMaxPacketSize        = 512,
            }
        }
    }
};

static const USBDescDevice desc_device = {
    .bcdUSB                        = 0x0200,
    .bDeviceClass                  = 0xEF,     /* Misc */
    .bDeviceSubClass               = 0x02,     /* Common */
    .bDeviceProtocol               = 0x01,     /* IAD */
    .bMaxPacketSize0               = 64,
    .bNumConfigurations            = 1,
    .confs = (USBDescConfig[]) {
        {
            .bNumInterfaces        = 5,
            .bConfigurationValue   = 1,
            .iConfiguration        = STR_RNDIS,
            .bmAttributes          = USB_CFG_ATT_ONE,
            .bMaxPower             = 50,
            .nif                   = 5,
            .ifs                   = desc_iface_serial_and_rndis,
        },
    },
};

static const USBDesc desc_wmodem = {
    .id = {
        .idVendor          = 0x1234,
        .idProduct         = 0x5678,
        .bcdDevice         = 0x0100,
        .iManufacturer     = STR_MANUFACTURER,
        .iProduct          = STR_PRODUCT,
        .iSerialNumber     = STR_SERIALNUMBER,
    },
    .full = &desc_device,
    .high = &desc_device,
    .str  = desc_strings,
};

/* ------------------------------------------------------------------ */
/* RNDIS definitions (from dev-network.c)                              */
/* ------------------------------------------------------------------ */

#define RNDIS_MAXIMUM_FRAME_SIZE        1518
#define RNDIS_MAX_TOTAL_SIZE            1558
#define RNDIS_MAJOR_VERSION             1
#define RNDIS_MINOR_VERSION             0

#define RNDIS_STATUS_SUCCESS            0x00000000U
#define RNDIS_STATUS_FAILURE            0xc0000001U
#define RNDIS_STATUS_NOT_SUPPORTED      0xc00000bbU

enum {
    RNDIS_PACKET_MSG            = 1,
    RNDIS_INITIALIZE_MSG        = 2,
    RNDIS_HALT_MSG              = 3,
    RNDIS_QUERY_MSG             = 4,
    RNDIS_SET_MSG                = 5,
    RNDIS_RESET_MSG             = 6,
    RNDIS_INDICATE_STATUS_MSG   = 7,
    RNDIS_KEEPALIVE_MSG         = 8,
};

enum {
    RNDIS_INITIALIZE_CMPLT      = 0x80000002U,
    RNDIS_QUERY_CMPLT           = 0x80000004U,
    RNDIS_SET_CMPLT             = 0x80000005U,
    RNDIS_RESET_CMPLT           = 0x80000006U,
    RNDIS_KEEPALIVE_CMPLT       = 0x80000008U,
};

enum {
    RNDIS_DF_CONNECTIONLESS     = 1,
};

#define RNDIS_MEDIUM_802_3              0x00000000U

typedef uint32_t le32;

typedef struct rndis_init_msg_type {
    le32 MessageType; le32 MessageLength; le32 RequestID;
    le32 MajorVersion; le32 MinorVersion; le32 MaxTransferSize;
} rndis_init_msg_type;

typedef struct rndis_init_cmplt_type {
    le32 MessageType; le32 MessageLength; le32 RequestID; le32 Status;
    le32 MajorVersion; le32 MinorVersion; le32 DeviceFlags; le32 Medium;
    le32 MaxPacketsPerTransfer; le32 MaxTransferSize;
    le32 PacketAlignmentFactor; le32 AFListOffset; le32 AFListSize;
} rndis_init_cmplt_type;

typedef struct rndis_halt_msg_type {
    le32 MessageType; le32 MessageLength; le32 RequestID;
} rndis_halt_msg_type;

typedef struct rndis_query_msg_type {
    le32 MessageType; le32 MessageLength; le32 RequestID; le32 OID;
    le32 InformationBufferLength; le32 InformationBufferOffset;
    le32 DeviceVcHandle;
} rndis_query_msg_type;

typedef struct rndis_query_cmplt_type {
    le32 MessageType; le32 MessageLength; le32 RequestID; le32 Status;
    le32 InformationBufferLength; le32 InformationBufferOffset;
} rndis_query_cmplt_type;

typedef struct rndis_set_msg_type {
    le32 MessageType; le32 MessageLength; le32 RequestID; le32 OID;
    le32 InformationBufferLength; le32 InformationBufferOffset;
    le32 DeviceVcHandle;
} rndis_set_msg_type;

typedef struct rndis_set_cmplt_type {
    le32 MessageType; le32 MessageLength; le32 RequestID; le32 Status;
} rndis_set_cmplt_type;

typedef struct rndis_reset_msg_type {
    le32 MessageType; le32 MessageLength; le32 Reserved;
} rndis_reset_msg_type;

typedef struct rndis_reset_cmplt_type {
    le32 MessageType; le32 MessageLength; le32 Status; le32 AddressingReset;
} rndis_reset_cmplt_type;

typedef struct rndis_keepalive_msg_type {
    le32 MessageType; le32 MessageLength; le32 RequestID;
} rndis_keepalive_msg_type;

typedef struct rndis_keepalive_cmplt_type {
    le32 MessageType; le32 MessageLength; le32 RequestID; le32 Status;
} rndis_keepalive_cmplt_type;

struct rndis_packet_msg_type {
    le32 MessageType; le32 MessageLength; le32 DataOffset; le32 DataLength;
    le32 OOBDataOffset; le32 OOBDataLength; le32 NumOOBDataElements;
    le32 PerPacketInfoOffset; le32 PerPacketInfoLength;
    le32 VcHandle; le32 Reserved;
};

enum rndis_state {
    RNDIS_UNINITIALIZED,
    RNDIS_INITIALIZED,
    RNDIS_DATA_INITIALIZED,
};

enum ndis_oid {
    OID_GEN_SUPPORTED_LIST              = 0x00010101,
    OID_GEN_HARDWARE_STATUS             = 0x00010102,
    OID_GEN_MEDIA_SUPPORTED             = 0x00010103,
    OID_GEN_MEDIA_IN_USE                = 0x00010104,
    OID_GEN_MAXIMUM_FRAME_SIZE          = 0x00010106,
    OID_GEN_LINK_SPEED                  = 0x00010107,
    OID_GEN_TRANSMIT_BLOCK_SIZE         = 0x0001010a,
    OID_GEN_RECEIVE_BLOCK_SIZE          = 0x0001010b,
    OID_GEN_VENDOR_ID                   = 0x0001010c,
    OID_GEN_VENDOR_DESCRIPTION          = 0x0001010d,
    OID_GEN_CURRENT_PACKET_FILTER       = 0x0001010e,
    OID_GEN_MAXIMUM_TOTAL_SIZE          = 0x00010111,
    OID_GEN_MAC_OPTIONS                 = 0x00010113,
    OID_GEN_MEDIA_CONNECT_STATUS        = 0x00010114,
    OID_GEN_PHYSICAL_MEDIUM             = 0x00010202,
    OID_GEN_XMIT_OK                     = 0x00020101,
    OID_GEN_RCV_OK                      = 0x00020102,
    OID_GEN_XMIT_ERROR                  = 0x00020103,
    OID_GEN_RCV_ERROR                   = 0x00020104,
    OID_GEN_RCV_NO_BUFFER               = 0x00020105,
    OID_802_3_PERMANENT_ADDRESS         = 0x01010101,
    OID_802_3_CURRENT_ADDRESS           = 0x01010102,
    OID_802_3_MULTICAST_LIST            = 0x01010103,
    OID_802_3_MAXIMUM_LIST_SIZE         = 0x01010104,
    OID_802_3_MAC_OPTIONS               = 0x01010105,
    OID_802_3_RCV_ERROR_ALIGNMENT       = 0x01020101,
    OID_802_3_XMIT_ONE_COLLISION        = 0x01020102,
    OID_802_3_XMIT_MORE_COLLISIONS      = 0x01020103,
};

static const uint32_t oid_supported_list[] = {
    OID_GEN_SUPPORTED_LIST,
    OID_GEN_HARDWARE_STATUS,
    OID_GEN_MEDIA_SUPPORTED,
    OID_GEN_MEDIA_IN_USE,
    OID_GEN_MAXIMUM_FRAME_SIZE,
    OID_GEN_LINK_SPEED,
    OID_GEN_TRANSMIT_BLOCK_SIZE,
    OID_GEN_RECEIVE_BLOCK_SIZE,
    OID_GEN_VENDOR_ID,
    OID_GEN_VENDOR_DESCRIPTION,
    OID_GEN_CURRENT_PACKET_FILTER,
    OID_GEN_MAXIMUM_TOTAL_SIZE,
    OID_GEN_MEDIA_CONNECT_STATUS,
    OID_GEN_PHYSICAL_MEDIUM,
    OID_GEN_XMIT_OK,
    OID_GEN_RCV_OK,
    OID_GEN_XMIT_ERROR,
    OID_GEN_RCV_ERROR,
    OID_GEN_RCV_NO_BUFFER,
    OID_802_3_PERMANENT_ADDRESS,
    OID_802_3_CURRENT_ADDRESS,
    OID_802_3_MULTICAST_LIST,
    OID_802_3_MAC_OPTIONS,
    OID_802_3_MAXIMUM_LIST_SIZE,
    OID_802_3_RCV_ERROR_ALIGNMENT,
    OID_802_3_XMIT_ONE_COLLISION,
    OID_802_3_XMIT_MORE_COLLISIONS,
};

#define NDIS_MAC_OPTION_RECEIVE_SERIALIZED      (1 << 1)
#define NDIS_MAC_OPTION_FULL_DUPLEX             (1 << 4)

struct rndis_response {
    QTAILQ_ENTRY(rndis_response) entries;
    uint32_t length;
    uint8_t buf[];
};

/* ------------------------------------------------------------------ */
/* device state                                                        */
/* ------------------------------------------------------------------ */

typedef struct WModemPort {
    CharFrontend cs;
    USBEndpoint *in_ep;
    uint8_t recv_buf[RECV_BUF];
    uint16_t recv_ptr;
    uint16_t recv_used;
} WModemPort;

struct USBWModemState {
    USBDevice dev;

    /* serial ports */
    WModemPort port[WMODEM_SERIAL_PORTS];

    /* rndis */
    int32_t rndis_state;
    uint32_t medium;
    uint32_t speed;
    uint32_t media_state;
    uint16_t filter;
    uint32_t vendorid;
    unsigned int out_ptr;
    uint8_t out_buf[2048];
    unsigned int in_ptr, in_len;
    uint8_t in_buf[2048];
    USBEndpoint *intr;
    USBEndpoint *bulk_in;
    char usbstring_mac[13];
    NICState *nic;
    NICConf conf;
    QTAILQ_HEAD(, rndis_response) rndis_resp;

    /* properties / per-instance descriptors */
    uint32_t vendorid_prop;
    uint32_t productid_prop;
    USBDesc desc;
    USBDescID desc_id;
};

#define TYPE_USB_WMODEM "usb-wmodem"
OBJECT_DECLARE_SIMPLE_TYPE(USBWModemState, USB_WMODEM)

/* ------------------------------------------------------------------ */
/* serial ports                                                        */
/* ------------------------------------------------------------------ */

static void usb_wmodem_port_reset(WModemPort *p)
{
    p->recv_ptr = 0;
    p->recv_used = 0;
}

static int usb_wmodem_port_can_read(void *opaque)
{
    WModemPort *p = opaque;

    return RECV_BUF - p->recv_used;
}

static void usb_wmodem_port_read(void *opaque, const uint8_t *buf, int size)
{
    WModemPort *p = opaque;
    int start, first;

    if (size > RECV_BUF - p->recv_used) {
        size = RECV_BUF - p->recv_used;
    }
    start = (p->recv_ptr + p->recv_used) % RECV_BUF;
    first = RECV_BUF - start;
    if (first > size) {
        first = size;
    }
    memcpy(p->recv_buf + start, buf, first);
    if (size > first) {
        memcpy(p->recv_buf, buf + first, size - first);
    }
    p->recv_used += size;

    usb_wakeup(p->in_ep, 0);
}

static void usb_wmodem_serial_in(USBWModemState *s, WModemPort *p,
                                 USBPacket *packet)
{
    int len, first;

    if (!p->recv_used) {
        packet->status = USB_RET_NAK;
        return;
    }
    len = (int)packet->iov.size;
    if (len > p->recv_used) {
        len = p->recv_used;
    }
    first = RECV_BUF - p->recv_ptr;
    if (first > len) {
        first = len;
    }
    usb_packet_copy(packet, p->recv_buf + p->recv_ptr, first);
    if (len > first) {
        usb_packet_copy(packet, p->recv_buf, len - first);
    }
    p->recv_ptr = (p->recv_ptr + len) % RECV_BUF;
    p->recv_used -= len;
}

static void usb_wmodem_serial_out(USBWModemState *s, WModemPort *p,
                                  USBPacket *packet)
{
    struct iovec *iov;
    int i;

    for (i = 0; i < packet->iov.niov; i++) {
        iov = packet->iov.iov + i;
        /* XXX blocks the vCPU thread; background I/O is a later optimization */
        qemu_chr_fe_write_all(&p->cs, iov->iov_base, iov->iov_len);
    }
    packet->actual_length = packet->iov.size;
}

/* ------------------------------------------------------------------ */
/* rndis (adapted from dev-network.c)                                  */
/* ------------------------------------------------------------------ */

static int ndis_query(USBWModemState *s, uint32_t oid,
                      uint8_t *inbuf, unsigned int inlen,
                      uint8_t *outbuf, size_t outlen)
{
    unsigned int i;

    switch (oid) {
    case OID_GEN_SUPPORTED_LIST:
        for (i = 0; i < ARRAY_SIZE(oid_supported_list); i++) {
            stl_le_p(outbuf + (i * sizeof(le32)), oid_supported_list[i]);
        }
        return sizeof(oid_supported_list);
    case OID_GEN_HARDWARE_STATUS:
        stl_le_p(outbuf, 0);
        return sizeof(le32);
    case OID_GEN_MEDIA_SUPPORTED:
    case OID_GEN_MEDIA_IN_USE:
        stl_le_p(outbuf, s->medium);
        return sizeof(le32);
    case OID_GEN_MAXIMUM_FRAME_SIZE:
    case OID_GEN_TRANSMIT_BLOCK_SIZE:
    case OID_GEN_RECEIVE_BLOCK_SIZE:
        stl_le_p(outbuf, ETH_FRAME_LEN);
        return sizeof(le32);
    case OID_GEN_LINK_SPEED:
        stl_le_p(outbuf, s->speed);
        return sizeof(le32);
    case OID_GEN_VENDOR_ID:
        stl_le_p(outbuf, s->vendorid);
        return sizeof(le32);
    case OID_GEN_VENDOR_DESCRIPTION:
        pstrcpy((char *)outbuf, outlen, "QEMU USB WMODEM RNDIS");
        return strlen((char *)outbuf) + 1;
    case OID_GEN_CURRENT_PACKET_FILTER:
        stl_le_p(outbuf, s->filter);
        return sizeof(le32);
    case OID_GEN_MAXIMUM_TOTAL_SIZE:
        stl_le_p(outbuf, RNDIS_MAX_TOTAL_SIZE);
        return sizeof(le32);
    case OID_GEN_MEDIA_CONNECT_STATUS:
        stl_le_p(outbuf, s->media_state);
        return sizeof(le32);
    case OID_GEN_PHYSICAL_MEDIUM:
        stl_le_p(outbuf, 0);
        return sizeof(le32);
    case OID_GEN_MAC_OPTIONS:
        stl_le_p(outbuf, NDIS_MAC_OPTION_RECEIVE_SERIALIZED |
                 NDIS_MAC_OPTION_FULL_DUPLEX);
        return sizeof(le32);
    case OID_GEN_XMIT_OK:
    case OID_GEN_RCV_OK:
    case OID_GEN_XMIT_ERROR:
    case OID_GEN_RCV_ERROR:
    case OID_GEN_RCV_NO_BUFFER:
        stl_le_p(outbuf, 0);
        return sizeof(le32);
    case OID_802_3_PERMANENT_ADDRESS:
    case OID_802_3_CURRENT_ADDRESS:
        memcpy(outbuf, s->conf.macaddr.a, 6);
        return 6;
    case OID_802_3_MULTICAST_LIST:
        stl_le_p(outbuf, 0xe0000000);
        return sizeof(le32);
    case OID_802_3_MAXIMUM_LIST_SIZE:
        stl_le_p(outbuf, 1);
        return sizeof(le32);
    case OID_802_3_MAC_OPTIONS:
        return 0;
    case OID_802_3_RCV_ERROR_ALIGNMENT:
    case OID_802_3_XMIT_ONE_COLLISION:
    case OID_802_3_XMIT_MORE_COLLISIONS:
        stl_le_p(outbuf, 0);
        return sizeof(le32);
    default:
        fprintf(stderr, "usb-wmodem: unknown OID 0x%08x\n", oid);
        return 0;
    }
}

static int ndis_set(USBWModemState *s, uint32_t oid,
                    uint8_t *inbuf, unsigned int inlen)
{
    switch (oid) {
    case OID_GEN_CURRENT_PACKET_FILTER:
        s->filter = ldl_le_p(inbuf);
        if (s->filter) {
            s->rndis_state = RNDIS_DATA_INITIALIZED;
        } else {
            s->rndis_state = RNDIS_INITIALIZED;
        }
        return 0;
    case OID_802_3_MULTICAST_LIST:
        return 0;
    }
    return -1;
}

static int rndis_get_response(USBWModemState *s, uint8_t *buf)
{
    int ret = 0;
    struct rndis_response *r = s->rndis_resp.tqh_first;

    if (!r) {
        return ret;
    }
    QTAILQ_REMOVE(&s->rndis_resp, r, entries);
    ret = r->length;
    memcpy(buf, r->buf, r->length);
    g_free(r);
    return ret;
}

static void *rndis_queue_response(USBWModemState *s, unsigned int length)
{
    struct rndis_response *r =
            g_malloc0(sizeof(struct rndis_response) + length);

    if (QTAILQ_EMPTY(&s->rndis_resp)) {
        usb_wakeup(s->intr, 0);
    }
    QTAILQ_INSERT_TAIL(&s->rndis_resp, r, entries);
    r->length = length;
    return &r->buf[0];
}

static void rndis_clear_responsequeue(USBWModemState *s)
{
    struct rndis_response *r;

    while ((r = s->rndis_resp.tqh_first)) {
        QTAILQ_REMOVE(&s->rndis_resp, r, entries);
        g_free(r);
    }
}

static int rndis_init_response(USBWModemState *s, rndis_init_msg_type *buf)
{
    rndis_init_cmplt_type *resp =
            rndis_queue_response(s, sizeof(rndis_init_cmplt_type));

    if (!resp) {
        return USB_RET_STALL;
    }
    resp->MessageType = cpu_to_le32(RNDIS_INITIALIZE_CMPLT);
    resp->MessageLength = cpu_to_le32(sizeof(rndis_init_cmplt_type));
    resp->RequestID = buf->RequestID;
    resp->Status = cpu_to_le32(RNDIS_STATUS_SUCCESS);
    resp->MajorVersion = cpu_to_le32(RNDIS_MAJOR_VERSION);
    resp->MinorVersion = cpu_to_le32(RNDIS_MINOR_VERSION);
    resp->DeviceFlags = cpu_to_le32(RNDIS_DF_CONNECTIONLESS);
    resp->Medium = cpu_to_le32(RNDIS_MEDIUM_802_3);
    resp->MaxPacketsPerTransfer = cpu_to_le32(1);
    resp->MaxTransferSize = cpu_to_le32(ETH_FRAME_LEN +
                    sizeof(struct rndis_packet_msg_type) + 22);
    resp->PacketAlignmentFactor = cpu_to_le32(0);
    resp->AFListOffset = cpu_to_le32(0);
    resp->AFListSize = cpu_to_le32(0);
    return 0;
}

static int rndis_query_response(USBWModemState *s,
                                rndis_query_msg_type *buf, unsigned int length)
{
    rndis_query_cmplt_type *resp;
    uint8_t infobuf[sizeof(oid_supported_list)];
    uint32_t bufoffs, buflen;
    int infobuflen;
    unsigned int resplen;

    bufoffs = le32_to_cpu(buf->InformationBufferOffset) + 8;
    buflen = le32_to_cpu(buf->InformationBufferLength);
    if (buflen > length || bufoffs >= length || bufoffs + buflen > length) {
        return USB_RET_STALL;
    }

    infobuflen = ndis_query(s, le32_to_cpu(buf->OID),
                            bufoffs + (uint8_t *)buf, buflen, infobuf,
                            sizeof(infobuf));
    resplen = sizeof(rndis_query_cmplt_type) +
            ((infobuflen < 0) ? 0 : infobuflen);
    resp = rndis_queue_response(s, resplen);
    if (!resp) {
        return USB_RET_STALL;
    }

    resp->MessageType = cpu_to_le32(RNDIS_QUERY_CMPLT);
    resp->RequestID = buf->RequestID;
    resp->MessageLength = cpu_to_le32(resplen);

    if (infobuflen < 0) {
        resp->Status = cpu_to_le32(RNDIS_STATUS_NOT_SUPPORTED);
        resp->InformationBufferLength = cpu_to_le32(0);
        resp->InformationBufferOffset = cpu_to_le32(0);
        return 0;
    }
    resp->Status = cpu_to_le32(RNDIS_STATUS_SUCCESS);
    resp->InformationBufferOffset =
            cpu_to_le32(infobuflen ? sizeof(rndis_query_cmplt_type) - 8 : 0);
    resp->InformationBufferLength = cpu_to_le32(infobuflen);
    memcpy(resp + 1, infobuf, infobuflen);
    return 0;
}

static int rndis_set_response(USBWModemState *s,
                              rndis_set_msg_type *buf, unsigned int length)
{
    rndis_set_cmplt_type *resp =
            rndis_queue_response(s, sizeof(rndis_set_cmplt_type));
    uint32_t bufoffs, buflen;
    int ret;

    if (!resp) {
        return USB_RET_STALL;
    }
    bufoffs = le32_to_cpu(buf->InformationBufferOffset) + 8;
    buflen = le32_to_cpu(buf->InformationBufferLength);
    if (buflen > length || bufoffs >= length || bufoffs + buflen > length) {
        return USB_RET_STALL;
    }
    ret = ndis_set(s, le32_to_cpu(buf->OID),
                   bufoffs + (uint8_t *)buf, buflen);
    resp->MessageType = cpu_to_le32(RNDIS_SET_CMPLT);
    resp->RequestID = buf->RequestID;
    resp->MessageLength = cpu_to_le32(sizeof(rndis_set_cmplt_type));
    if (ret < 0) {
        resp->Status = cpu_to_le32(RNDIS_STATUS_NOT_SUPPORTED);
        return 0;
    }
    resp->Status = cpu_to_le32(RNDIS_STATUS_SUCCESS);
    return 0;
}

static int rndis_reset_response(USBWModemState *s, rndis_reset_msg_type *buf)
{
    rndis_reset_cmplt_type *resp =
            rndis_queue_response(s, sizeof(rndis_reset_cmplt_type));

    if (!resp) {
        return USB_RET_STALL;
    }
    resp->MessageType = cpu_to_le32(RNDIS_RESET_CMPLT);
    resp->MessageLength = cpu_to_le32(sizeof(rndis_reset_cmplt_type));
    resp->Status = cpu_to_le32(RNDIS_STATUS_SUCCESS);
    resp->AddressingReset = cpu_to_le32(1);
    return 0;
}

static int rndis_keepalive_response(USBWModemState *s,
                                    rndis_keepalive_msg_type *buf)
{
    rndis_keepalive_cmplt_type *resp =
            rndis_queue_response(s, sizeof(rndis_keepalive_cmplt_type));

    if (!resp) {
        return USB_RET_STALL;
    }
    resp->MessageType = cpu_to_le32(RNDIS_KEEPALIVE_CMPLT);
    resp->MessageLength = cpu_to_le32(sizeof(rndis_keepalive_cmplt_type));
    resp->RequestID = buf->RequestID;
    resp->Status = cpu_to_le32(RNDIS_STATUS_SUCCESS);
    return 0;
}

static void usb_wmodem_reset_in_buf(USBWModemState *s)
{
    s->in_ptr = s->in_len = 0;
    if (s->nic) {
        qemu_flush_queued_packets(qemu_get_queue(s->nic));
    }
}

static int rndis_parse(USBWModemState *s, uint8_t *data, int length)
{
    uint32_t msg_type = ldl_le_p(data);

    switch (msg_type) {
    case RNDIS_INITIALIZE_MSG:
        s->rndis_state = RNDIS_INITIALIZED;
        return rndis_init_response(s, (rndis_init_msg_type *)data);
    case RNDIS_HALT_MSG:
        s->rndis_state = RNDIS_UNINITIALIZED;
        return 0;
    case RNDIS_QUERY_MSG:
        return rndis_query_response(s, (rndis_query_msg_type *)data, length);
    case RNDIS_SET_MSG:
        return rndis_set_response(s, (rndis_set_msg_type *)data, length);
    case RNDIS_RESET_MSG:
        rndis_clear_responsequeue(s);
        s->out_ptr = 0;
        usb_wmodem_reset_in_buf(s);
        return rndis_reset_response(s, (rndis_reset_msg_type *)data);
    case RNDIS_KEEPALIVE_MSG:
        return rndis_keepalive_response(s, (rndis_keepalive_msg_type *)data);
    }
    return USB_RET_STALL;
}

/* ------------------------------------------------------------------ */
/* USB handlers                                                        */
/* ------------------------------------------------------------------ */

static void usb_wmodem_handle_reset(USBDevice *dev)
{
    USBWModemState *s = USB_WMODEM(dev);
    int i;

    for (i = 0; i < WMODEM_SERIAL_PORTS; i++) {
        usb_wmodem_port_reset(&s->port[i]);
    }
}

static void usb_wmodem_handle_statusin(USBWModemState *s, USBPacket *p)
{
    le32 rbuf[2];

    if (p->iov.size < 8) {
        p->status = USB_RET_STALL;
        return;
    }
    rbuf[0] = cpu_to_le32(1);
    rbuf[1] = cpu_to_le32(0);
    usb_packet_copy(p, rbuf, 8);
    if (!s->rndis_resp.tqh_first) {
        p->status = USB_RET_NAK;
    }
}

static void usb_wmodem_handle_datain(USBWModemState *s, USBPacket *p)
{
    int len;

    if (s->in_ptr > s->in_len) {
        usb_wmodem_reset_in_buf(s);
        p->status = USB_RET_NAK;
        return;
    }
    if (!s->in_len) {
        p->status = USB_RET_NAK;
        return;
    }
    len = s->in_len - s->in_ptr;
    if (len > p->iov.size) {
        len = p->iov.size;
    }
    usb_packet_copy(p, &s->in_buf[s->in_ptr], len);
    s->in_ptr += len;
    if (s->in_ptr >= s->in_len) {
        usb_wmodem_reset_in_buf(s);
    }
}

static void usb_wmodem_handle_dataout(USBWModemState *s, USBPacket *p)
{
    int sz = sizeof(s->out_buf) - s->out_ptr;
    struct rndis_packet_msg_type *msg = (struct rndis_packet_msg_type *)s->out_buf;
    uint32_t len;

    if (sz > p->iov.size) {
        sz = p->iov.size;
    }
    usb_packet_copy(p, &s->out_buf[s->out_ptr], sz);
    s->out_ptr += sz;

    len = le32_to_cpu(msg->MessageLength);
    if (s->out_ptr < 8 || s->out_ptr < len) {
        return;
    }
    if (le32_to_cpu(msg->MessageType) == RNDIS_PACKET_MSG) {
        uint32_t offs = 8 + le32_to_cpu(msg->DataOffset);
        uint32_t size = le32_to_cpu(msg->DataLength);
        if (offs < len && size < len && offs + size <= len) {
            qemu_send_packet(qemu_get_queue(s->nic), s->out_buf + offs, size);
        }
    }
    s->out_ptr -= len;
    memmove(s->out_buf, &s->out_buf[len], s->out_ptr);
}

static void usb_wmodem_handle_control(USBDevice *dev, USBPacket *p,
                                      int request, int value, int index,
                                      int length, uint8_t *data)
{
    USBWModemState *s = USB_WMODEM(dev);
    int ret;

    ret = usb_desc_handle_control(dev, p, request, value, index, length, data);
    if (ret >= 0) {
        return;
    }

    switch (request) {
    case ClassInterfaceOutRequest | USB_CDC_SEND_ENCAPSULATED_COMMAND:
        if (value || index != RNDIS_CTRL_IF) {
            goto fail;
        }
        ret = rndis_parse(s, data, length);
        if (ret < 0) {
            p->status = ret;
        }
        break;

    case ClassInterfaceRequest | USB_CDC_GET_ENCAPSULATED_RESPONSE:
        if (value || index != RNDIS_CTRL_IF) {
            goto fail;
        }
        p->actual_length = rndis_get_response(s, data);
        if (p->actual_length == 0) {
            data[0] = 0;
            p->actual_length = 1;
        }
        break;

    case EndpointOutRequest | USB_REQ_CLEAR_FEATURE:
        break;

    default:
    fail:
        p->status = USB_RET_STALL;
        break;
    }
}

static void usb_wmodem_handle_data(USBDevice *dev, USBPacket *p)
{
    USBWModemState *s = USB_WMODEM(dev);
    uint8_t nr = p->ep->nr;

    switch (p->pid) {
    case USB_TOKEN_IN:
        /* ep 1/2/3: serial ports; ep 4: rndis status; ep 5: rndis data */
        if (nr >= 1 && nr <= WMODEM_SERIAL_PORTS) {
            usb_wmodem_serial_in(s, &s->port[nr - 1], p);
        } else if (nr == 4) {
            usb_wmodem_handle_statusin(s, p);
        } else if (nr == 5) {
            usb_wmodem_handle_datain(s, p);
        } else {
            p->status = USB_RET_STALL;
        }
        break;

    case USB_TOKEN_OUT:
        if (nr >= 1 && nr <= WMODEM_SERIAL_PORTS) {
            usb_wmodem_serial_out(s, &s->port[nr - 1], p);
        } else if (nr == 4) {
            usb_wmodem_handle_dataout(s, p);
        } else {
            p->status = USB_RET_STALL;
        }
        break;

    default:
        p->status = USB_RET_STALL;
        break;
    }
}

/* netdev receive: host-side packet -> guest (RNDIS framed) */
static ssize_t usb_wmodem_receive(NetClientState *nc, const uint8_t *buf,
                                  size_t size)
{
    USBWModemState *s = qemu_get_nic_opaque(nc);
    uint8_t *in_buf = s->in_buf;
    size_t total_size = size + sizeof(struct rndis_packet_msg_type);
    struct rndis_packet_msg_type *msg;

    if (!s->dev.config) {
        return -1;
    }
    if (s->rndis_state != RNDIS_DATA_INITIALIZED) {
        return -1;
    }
    if (total_size > sizeof(s->in_buf)) {
        return -1;
    }
    if (s->in_len > 0) {
        return 0;
    }

    msg = (struct rndis_packet_msg_type *)in_buf;
    memset(msg, 0, sizeof(struct rndis_packet_msg_type));
    msg->MessageType = cpu_to_le32(RNDIS_PACKET_MSG);
    msg->MessageLength = cpu_to_le32(total_size);
    msg->DataOffset = cpu_to_le32(sizeof(*msg) - 8);
    msg->DataLength = cpu_to_le32(size);
    in_buf += sizeof(*msg);

    memcpy(in_buf, buf, size);
    s->in_len = total_size;
    s->in_ptr = 0;
    usb_wakeup(s->bulk_in, 0);
    return size;
}

static void usb_wmodem_cleanup(NetClientState *nc)
{
    USBWModemState *s = qemu_get_nic_opaque(nc);

    s->nic = NULL;
}

static NetClientInfo net_wmodem_info = {
    .type = NET_CLIENT_DRIVER_NIC,
    .size = sizeof(NICState),
    .receive = usb_wmodem_receive,
    .cleanup = usb_wmodem_cleanup,
};

/* ------------------------------------------------------------------ */
/* realize / unrealize / properties                                    */
/* ------------------------------------------------------------------ */

static void usb_wmodem_unrealize(USBDevice *dev)
{
    USBWModemState *s = USB_WMODEM(dev);

    rndis_clear_responsequeue(s);
    if (s->nic) {
        qemu_del_nic(s->nic);
        s->nic = NULL;
    }
}

static void usb_wmodem_realize(USBDevice *dev, Error **errp)
{
    USBWModemState *s = USB_WMODEM(dev);
    int i;

    /* per-instance descriptor copy -> dynamic VID/PID */
    s->desc_id = desc_wmodem.id;
    s->desc_id.idVendor = s->vendorid_prop;
    s->desc_id.idProduct = s->productid_prop;
    s->desc = desc_wmodem;
    s->desc.id = s->desc_id;
    dev->usb_desc = &s->desc;

    usb_desc_init(dev);

    /* serial ports: port0 (AT) requires a chardev; others optional */
    if (!qemu_chr_fe_backend_connected(&s->port[0].cs)) {
        error_setg(errp, "usb-wmodem: property chardev (AT port) is required");
        return;
    }
    for (i = 0; i < WMODEM_SERIAL_PORTS; i++) {
        WModemPort *p = &s->port[i];
        p->in_ep = usb_ep_get(dev, USB_TOKEN_IN, i + 1);
        usb_wmodem_port_reset(p);
        if (qemu_chr_fe_backend_connected(&p->cs)) {
            qemu_chr_fe_set_handlers(&p->cs, usb_wmodem_port_can_read,
                                     usb_wmodem_port_read, NULL, NULL, p,
                                     NULL, true);
        }
    }

    /* rndis */
    s->rndis_state = RNDIS_UNINITIALIZED;
    QTAILQ_INIT(&s->rndis_resp);
    s->medium = 0;          /* NDIS_MEDIUM_802_3 */
    s->speed = 1000000;     /* 100Mbps, in 100bps units */
    s->media_state = 0;     /* connected */
    s->filter = 0;
    s->vendorid = s->vendorid_prop;
    s->intr = usb_ep_get(dev, USB_TOKEN_IN, 4);
    s->bulk_in = usb_ep_get(dev, USB_TOKEN_IN, 5);

    qemu_macaddr_default_if_unset(&s->conf.macaddr);
    s->nic = qemu_new_nic(&net_wmodem_info, &s->conf,
                          object_get_typename(OBJECT(s)), s->dev.qdev.id,
                          &s->dev.qdev.mem_reentrancy_guard, s);
    qemu_format_nic_info_str(qemu_get_queue(s->nic), s->conf.macaddr.a);
    snprintf(s->usbstring_mac, sizeof(s->usbstring_mac), "%02x%02x%02x%02x%02x%02x",
             0x40, s->conf.macaddr.a[1], s->conf.macaddr.a[2],
             s->conf.macaddr.a[3], s->conf.macaddr.a[4], s->conf.macaddr.a[5]);
    usb_desc_set_string(dev, STR_ETHADDR, s->usbstring_mac);
}

static const VMStateDescription vmstate_wmodem_port = {
    .name = "usb-wmodem/port",
    .version_id = 1,
    .minimum_version_id = 1,
    .fields = (const VMStateField[]) {
        VMSTATE_UINT16(recv_ptr, WModemPort),
        VMSTATE_UINT16(recv_used, WModemPort),
        VMSTATE_BUFFER(recv_buf, WModemPort),
        VMSTATE_END_OF_LIST()
    },
};

static const VMStateDescription vmstate_usb_wmodem = {
    .name = "usb-wmodem",
    .version_id = 1,
    .minimum_version_id = 1,
    .fields = (const VMStateField[]) {
        VMSTATE_USB_DEVICE(dev, USBWModemState),
        VMSTATE_INT32(rndis_state, USBWModemState),
        VMSTATE_UINT32(medium, USBWModemState),
        VMSTATE_UINT32(speed, USBWModemState),
        VMSTATE_UINT32(media_state, USBWModemState),
        VMSTATE_UINT16(filter, USBWModemState),
        VMSTATE_UINT32(out_ptr, USBWModemState),
        VMSTATE_BUFFER(out_buf, USBWModemState),
        VMSTATE_UINT32(in_ptr, USBWModemState),
        VMSTATE_UINT32(in_len, USBWModemState),
        VMSTATE_BUFFER(in_buf, USBWModemState),
        VMSTATE_STRUCT_ARRAY(port, USBWModemState, WMODEM_SERIAL_PORTS, 1,
                             vmstate_wmodem_port, WModemPort),
        VMSTATE_END_OF_LIST()
    },
};

static const Property wmodem_properties[] = {
    DEFINE_PROP_CHR("chardev", USBWModemState, port[0].cs),
    DEFINE_PROP_CHR("serial1", USBWModemState, port[1].cs),
    DEFINE_PROP_CHR("serial2", USBWModemState, port[2].cs),
    DEFINE_PROP_UINT32("vendorid", USBWModemState, vendorid_prop, 0x1234),
    DEFINE_PROP_UINT32("productid", USBWModemState, productid_prop, 0x5678),
    DEFINE_NIC_PROPERTIES(USBWModemState, conf),
};

static void usb_wmodem_class_init(ObjectClass *klass, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    USBDeviceClass *uc = USB_DEVICE_CLASS(klass);

    uc->product_desc   = "QEMU USB WMODEM";
    uc->usb_desc       = &desc_wmodem;
    uc->realize        = usb_wmodem_realize;
    uc->unrealize      = usb_wmodem_unrealize;
    uc->handle_reset   = usb_wmodem_handle_reset;
    uc->handle_control = usb_wmodem_handle_control;
    uc->handle_data    = usb_wmodem_handle_data;
    dc->vmsd = &vmstate_usb_wmodem;
    device_class_set_props(dc, wmodem_properties);
    set_bit(DEVICE_CATEGORY_NETWORK, dc->categories);
}

static const TypeInfo wmodem_info = {
    .name          = TYPE_USB_WMODEM,
    .parent        = TYPE_USB_DEVICE,
    .instance_size = sizeof(USBWModemState),
    .class_init    = usb_wmodem_class_init,
};

static void usb_wmodem_register_types(void)
{
    type_register_static(&wmodem_info);
}

type_init(usb_wmodem_register_types)

/* ----------------------------------------------------------------------- *
 *
 *   Copyright 2009 Erwan Velu - All Rights Reserved
 *
 *   Permission is hereby granted, free of charge, to any person
 *   obtaining a copy of this software and associated documentation
 *   files (the "Software"), to deal in the Software without
 *   restriction, including without limitation the rights to use,
 *   copy, modify, merge, publish, distribute, sublicense, and/or
 *   sell copies of the Software, and to permit persons to whom
 *   the Software is furnished to do so, subject to the following
 *   conditions:
 *
 *   The above copyright notice and this permission notice shall
 *   be included in all copies or substantial portions of the Software.
 *
 *   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 *   EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 *   OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 *   NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 *   HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 *   WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 *   FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 *   OTHER DEALINGS IN THE SOFTWARE.
 *
 * -----------------------------------------------------------------------
*/

#ifndef DEFINE_HDT_COMMON_H
#define DEFINE_HDT_COMMON_H
#include <stdio.h>
#include "sys/pci.h"
#include "cpuid.h"
#include "dmi/dmi.h"
#include <syslinux/pxe.h>
#include "hdt-ata.h"

/* This two values are used for switching for the menu to the CLI mode*/
#define HDT_SWITCH_TO_CLI "hdt_switch_to_cli"
#define HDT_RETURN_TO_CLI 100

extern int display_line_nb;

#define more_printf(...) do {\
 if (display_line_nb == 23) {\
   char tempbuf[10];\
   printf("Press enter to continue\n");\
   display_line_nb=0;\
   fgets(tempbuf, sizeof(tempbuf), stdin);\
 }\
 printf ( __VA_ARGS__);\
 display_line_nb++; \
} while (0);


struct s_pxe {
 uint16_t vendor_id;
 uint16_t product_id;
 uint16_t subvendor_id;
 uint16_t subproduct_id;
 uint8_t rev;
 uint8_t pci_bus;
 uint8_t pci_dev;
 uint8_t pci_func;
 uint8_t base_class;
 uint8_t sub_class;
 uint8_t prog_intf;
 uint8_t nictype;
 char mac_addr[18]; /* The current mac address */
 uint8_t ip_addr[4];

 pxe_bootp_t dhcpdata; /* The dhcp answer */
 struct pci_device *pci_device; /* The matching pci device */
 uint8_t pci_device_pos; /* It position in our pci sorted list*/

};

struct s_hardware {
  s_dmi dmi; /* DMI table */
  s_cpu cpu; /* CPU information */
  struct pci_domain *pci_domain; /* PCI Devices */
  struct diskinfo disk_info[256];     /* Disk Information*/
  struct s_pxe pxe;

  int pci_ids_return_code;
  int modules_pcimap_return_code;
  int nb_pci_devices;
  bool is_dmi_valid;
  bool is_pxe_valid;

  bool dmi_detection; /* Does the dmi stuff have been already detected */
  bool pci_detection; /* Does the pci stuff have been already detected */
  bool cpu_detection; /* Does the cpu stuff have been already detected */
  bool disk_detection; /* Does the disk stuff have been already detected */
  bool pxe_detection; /* Does the pxe stuff have been already detected*/
};

char *find_argument(const char **argv, const char *argument);
int detect_dmi(struct s_hardware *hardware);
void detect_disks(struct s_hardware *hardware);
void detect_pci(struct s_hardware *hardware);
void cpu_detect(struct s_hardware *hardware);
int detect_pxe(struct s_hardware *hardware);
void init_hardware(struct s_hardware *hardware);
void clear_screen(void);
#endif

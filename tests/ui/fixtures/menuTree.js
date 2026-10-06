/* fixture: excerpt shaped like /www/require/modules/menuTree.js (VPN block is verbatim from the router) */
var menuTree = {
	list: [
		{
			menuName: "<#2905#>",
			index: "menu_Guest_Network",
			tab: [
				{url: "Guest_network.asp", tabName: "__INHERIT__"},
				{url: "NULL", tabName: "__INHERIT__"}
			]
		},
		{
			menuName: "<#303#>",
			index: "menu_Firewall",
			tab: [
				{url: "Advanced_BasicFirewall_Content.asp", tabName: "__INHERIT__"},
				{url: "Advanced_URLFilter_Content.asp", tabName: "__INHERIT__"},
				{url: "NULL", tabName: "__INHERIT__"}
			]
		},
		{
menuName: "VPN",
index: "menu_VPN",
tab: [
{url: "Advanced_VPNStatus.asp", tabName: "VPN Status"},
{url: "Advanced_VPNDirector.asp", tabName: "VPN Director"},
{url: "Advanced_VPN_OpenVPN.asp", tabName: "<#260#>"},
{url: "Advanced_VPN_PPTP.asp", tabName: "__INHERIT__"},
{url: "Advanced_VPN_IPSec.asp", tabName: "__INHERIT__"},
{url: "Advanced_OpenVPNClient_Content.asp", tabName: (vpn_fusion_support) ? "<#4339#>" : "<#3879#>"},
{url: "Advanced_VPNClient_Content.asp", tabName: "__INHERIT__"},
{url: "NULL", tabName: "__INHERIT__"}
]
		},
		{
			menuName: "<#2921#>",
			index: "menu_Advanced_Settings",
			tab: [
				{url: "Advanced_SwitchCtrl_Content.asp", tabName: "Switch Control"},
				{url: "user1.asp", tabName: "Diversion"},
				{url: "Advanced_ASUSDDNS_Content.asp", tabName: "__INHERIT__"},
				{url: "NULL", tabName: "__INHERIT__"}
			]
		}
	],
	exclude: {
		menus: function(){ return []; }
	}
};

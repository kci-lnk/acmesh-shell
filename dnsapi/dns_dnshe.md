# DNSHE Free Domains

Create an API Key and API Secret in API Management under Manage Domains in the DNSHE client area. Set `DNSHE_API_KEY` and `DNSHE_API_SECRET` in the process environment, then run:

```sh
./acme.sh --issue --dns dns_dnshe -d your-domain -d '*.your-domain'
```

Use the full DNSHE domain registered to your account. The hook discovers the managed zone and saves the credentials in acme.sh's account configuration for automatic renewal.

[DNSHE Free Domains API reference](https://github.com/dnshe/DNSHE-FreeDomains/blob/main/docs/api.md)

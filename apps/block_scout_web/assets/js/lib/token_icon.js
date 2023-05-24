async function getTokenIconUrl (chainID, addressHash) {
  let chainName = null
  switch (chainID) {
    case '1':
      chainName = 'ethereum'
      break
    case '99':
      chainName = 'poa'
      break
    case '100':
      chainName = 'xdai'
      break
    case '369':
      chainName = 'pulsechain'
      break
    case '943':
      chainName = 'pulsechain-testnet-v4'
      break
    default:
      chainName = null
      break
  }
  if (chainName) {
    if (await checkLink(`https://tokens.app.pulsex.com/images/tokens/${addressHash}.png`)) {
      return `https://tokens.app.pulsex.com/images/tokens/${addressHash}.png`
    }

    if (await checkLink(`https://tokens.app.v4.testnet.pulsex.com/images/tokens/${addressHash}.png`)) {
      return `https://tokens.app.v4.testnet.pulsex.com/images/tokens/${addressHash}.png`
    }

    if (await checkLink(`https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/${chainName}/assets/${addressHash}/logo.png`)) {
      return `https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/${chainName}/assets/${addressHash}/logo.png`
    }

    return `https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/${addressHash}/logo.png`
  } else {
    return '/images/icons/token_icon_default.svg'
  }
}

function appendTokenIcon ($tokenIconContainer, chainID, addressHash, displayTokenIcons, size) {
  const iconSize = size || 20
  getTokenIconUrl(chainID.toString(), addressHash).then((tokenIconURL) => {
    if (displayTokenIcons) {
      checkLink(tokenIconURL).then(checkTokenIconLink => {
        if (checkTokenIconLink) {
          if ($tokenIconContainer) {
            const img = new Image(iconSize, iconSize)
            img.src = tokenIconURL
            img.className = 'mr-1'
            $tokenIconContainer.append(img)
          }
        }
      })
    }
  })
}

async function checkLink (url) {
  if (url) {
    try {
      const res = await fetch(url)
      return res.ok
    } catch (_error) {
      return false
    }
  } else {
    return false
  }
}

export { appendTokenIcon, checkLink, getTokenIconUrl }

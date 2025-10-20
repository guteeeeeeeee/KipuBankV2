**Kipu Bank V2** esta nueva version es una mejora respecto al Kipu Bank original  
Ademas de las funciones originales ahora se agrego:
- poder transferir y retirar tanto ETH como token ERC-20
- se mantiene actualizado el saldo de cada usuario respecto al monto de los tokens que posee
- y el banco posee en usd6 los valores de todos los depositos realizados para poder realizar la contabilidad interna
- se usan los Data Feeds de Chainlink para convertir valores en ETH a USD y controlar el límite del banco
- tambien permite manejar diferentes decimales de activos y convertirlos a los decimales de USDC para la contabilidad interna
- ademas se agrego el rol de administrador que permite realizar funciones especiales

para depositar ETH => llamar a depositETH
para retirar ETH => llamar a withdrawETH
para depositar token ERC-20 => depositToken
para retirar token ERC-20 => withdrawToken

Esta desplegado en **sepolia** testnet
direccion => 0xdb2b95d3E8892AcB57B3f6FB5598925B29dAC649

url de etherscan =>
https://sepolia.etherscan.io/address/0xdb2b95d3e8892acb57b3f6fb5598925b29dac649#code

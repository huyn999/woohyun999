import java.util.HashMap;
import java.util.Map;

public class BankManager {
    private Map<String, BankAccount> accounts = new HashMap<>();

    public void addAccount(BankAccount account) throws DuplicateAccountException {
        if (accounts.containsKey(account.getAccountNumber())) // 중복된 키 값 발견시 오류 발생 시킴
        {
            throw new DuplicateAccountException("This Account already exists.");
        }
        else
        {
            accounts.put(account.getAccountNumber(), account);
        }

    }

    public BankAccount findAccount(String accountNumber) throws AccountNotFoundException {
        if (!accounts.containsKey(accountNumber))
        {
            throw new AccountNotFoundException("This Account doesn’t exist.");
        }
        else {
            return accounts.get(accountNumber); // map이니 get()을 사용하여 키 값으로 value 값 접근
        }
    }

    public void deposit(String accountNumber, double amount) throws AccountNotFoundException {
        BankAccount myaccount = findAccount(accountNumber);
        myaccount.deposit(amount);
    }

    public void withdraw(String accountNumber, double amount) throws AccountNotFoundException, InsufficientBalanceException
    {
        BankAccount myaccount = findAccount(accountNumber);
        myaccount.withdraw(amount);
    }

    public void printAllAccounts() {
        if (accounts.size()==0)
        {
            System.out.println("There are no Accounts.");
        }
        else
        {
            for (String accountnumber : accounts.keySet())
            { // accounts 맵의 키 값을 이용하여 반복
                BankAccount myaccount = accounts.get(accountnumber);
                System.out.println("[Account Number: " + myaccount.getAccountNumber() +
                        ", Balance: " + myaccount.getBalance()+"]");
            }

        }

    }
}
